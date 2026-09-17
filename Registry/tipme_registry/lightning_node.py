"""Real Lightning movement, via Voltage's Payments API (credit-backed).

This is a money-transmission integration for the *test-with-your-own-funds*
phase of the custodial pivot -- deliberately scoped to Lightning only for
now. On-chain Bitcoin sends/receives and USDT/Tron are separate follow-ups,
each its own protocol and its own real-money testing pass.

## Which Voltage product this actually is

Voltage offers two different things, and this integration is against the
second one:

  - A raw, customer-run Lightning node ("node-backed") -- macaroons, channel
    liquidity, node security, all on the operator. An earlier version of
    this module was written against that one, from LND's own REST API,
    before an actual Voltage account showed the wallet in use here is the
    other kind.
  - **Voltage Payments API, credit-backed** -- Voltage runs the node;
    the operator gets a wallet with a line of credit and a plain REST API
    (`docs.voltageapi.com`) scoped to an organization, environment and
    wallet. This is what `VoltagePaymentsRail` below talks to.

`LightningRail` is the seam that made discovering this a non-event: the
protocol didn't change, only this one class's HTTP internals did. Swapping
providers again later, or moving to a different rail entirely, means writing
another class against the same protocol -- nothing above it (the ledger, the
endpoints, the app) changes. This is the same seam `PaymentBackend` already
is for the tip-sending path.

## Honesty about what is verified here

Voltage's docs site and API are both unreachable from this environment's
network (same egress block that made the Instagram og:title work
guesswork-then-correct, not fetch-and-verify). What's confirmed, from
screenshots of the actual account this integration targets, is the resource
shape: wallets and payments are REST resources under
`/organizations/{organization_id}/[environments/{environment_id}/]...`, with
list/create/get operations on each, an API key issued from the dashboard's
"API Keys" page, and separate "Quotes" and "Lines of Credit" resources this
module does not yet use. The exact request/response *field names* below
(`direction`, `payment_kind`, `amount_msats`, ...) are informed inference
from that shape and from how Lightning payment APIs conventionally look, not
confirmed. Expect this to need one real correction pass, the same way the
Instagram title parsing did -- but the feedback loop here is a Python
exception with Voltage's actual error message in it, not a rebuilt iOS app,
so it should be a fast one.

## Configuration

Reads ``REGISTRY_VOLTAGE_API_KEY``, ``REGISTRY_VOLTAGE_ORGANIZATION_ID``,
``REGISTRY_VOLTAGE_ENVIRONMENT_ID``, ``REGISTRY_VOLTAGE_WALLET_ID`` and
``REGISTRY_VOLTAGE_LINE_OF_CREDIT_ID``. Until all five are set,
``rail_from_env`` returns ``None`` and the deposit/withdraw endpoints fail
closed with a 503, the same convention ``oauth.config_for`` already uses for
Instagram/TikTok.

Every one of these carries the ``REGISTRY_`` prefix deliberately:
``Scripts/make-xcconfig.sh`` strips exactly that prefix from what reaches the
iOS app bundle, so a differently-named credential here would ship inside the
compiled app -- a real Lightning API key, extractable by anyone who
decompiles the binary.
"""
from __future__ import annotations

import asyncio
import os
import uuid
from dataclasses import dataclass
from typing import Protocol

import httpx


class LightningNodeError(Exception):
    """Voltage was reached but the call did not succeed -- a payment that
    doesn't exist, insufficient credit, a malformed request."""


@dataclass(frozen=True)
class LightningNodeConfig:
    api_base_url: str
    api_key: str
    organization_id: str
    environment_id: str
    wallet_id: str
    # A wallet's line of credit, from that wallet's own resource
    # (`line_of_credit_id` in `GET .../wallets/{wallet_id}`). Real testing
    # showed both quoting and sending require it explicitly -- it isn't
    # inferred from the wallet_id server-side.
    line_of_credit_id: str


def config_from_env() -> LightningNodeConfig | None:
    api_key = os.environ.get("REGISTRY_VOLTAGE_API_KEY")
    organization_id = os.environ.get("REGISTRY_VOLTAGE_ORGANIZATION_ID")
    environment_id = os.environ.get("REGISTRY_VOLTAGE_ENVIRONMENT_ID")
    wallet_id = os.environ.get("REGISTRY_VOLTAGE_WALLET_ID")
    line_of_credit_id = os.environ.get("REGISTRY_VOLTAGE_LINE_OF_CREDIT_ID")
    if not (api_key and organization_id and environment_id and wallet_id and line_of_credit_id):
        return None
    base_url = os.environ.get("REGISTRY_VOLTAGE_API_BASE_URL", "https://voltageapi.com/v1")
    return LightningNodeConfig(
        api_base_url=base_url.rstrip("/"), api_key=api_key,
        organization_id=organization_id, environment_id=environment_id, wallet_id=wallet_id,
        line_of_credit_id=line_of_credit_id,
    )


@dataclass(frozen=True)
class Invoice:
    payment_request: str
    payment_hash: str
    amount_sats: int


@dataclass(frozen=True)
class InvoiceStatus:
    settled: bool
    amount_sats: int


@dataclass(frozen=True)
class DecodedInvoice:
    amount_sats: int
    destination: str
    description: str


@dataclass(frozen=True)
class PaymentResult:
    payment_hash: str
    fee_sats: int


class LightningRail(Protocol):
    """What the deposit/withdraw endpoints need from a Lightning rail.

    ``payment_hash`` in `invoice_status`/`PaymentResult` is this rail's own
    opaque identifier for a payment -- a real BOLT11 payment hash for a
    node-backed rail, Voltage's own payment id for the credit-backed one.
    Callers never decode or compare it themselves; it only ever round-trips
    back into the same rail.
    """

    async def create_invoice(self, amount_sats: int, memo: str) -> Invoice: ...

    async def invoice_status(self, payment_hash: str) -> InvoiceStatus: ...

    async def decode_invoice(self, payment_request: str) -> DecodedInvoice: ...

    async def pay_invoice(self, payment_request: str) -> PaymentResult: ...


class VoltagePaymentsRail:
    """Talks to Voltage's Payments API for a single credit-backed BTC
    wallet. See the module docstring -- the exact field names here are
    informed inference, not confirmed against a real response, and are the
    first thing to check if this starts throwing."""

    def __init__(self, config: LightningNodeConfig):
        self._config = config

    def _client(self, timeout: float) -> httpx.AsyncClient:
        # Confirmed against a real Voltage account: it's `X-Api-Key`, not a
        # standard `Authorization: Bearer` header -- the latter authenticates
        # as nothing and comes back "Invalid token" regardless of how valid
        # the key actually is.
        return httpx.AsyncClient(
            base_url=self._config.api_base_url,
            timeout=timeout,
            headers={"X-Api-Key": self._config.api_key},
        )

    def _payments_path(self, suffix: str = "") -> str:
        return (
            f"/organizations/{self._config.organization_id}"
            f"/environments/{self._config.environment_id}/payments{suffix}"
        )

    @staticmethod
    def _check(response: httpx.Response) -> None:
        """Raises with Voltage's own error text, not just the status code.

        `response.raise_for_status()` alone throws away the response body --
        which is exactly where a 400 explains *which* field it didn't like.
        That blindness cost a whole round of guessing already; this is what
        makes the next error message actually actionable.
        """
        if response.is_success:
            return
        raise LightningNodeError(
            f"Voltage returned {response.status_code}: {response.text}"
        )

    async def create_invoice(self, amount_sats: int, memo: str) -> Invoice:
        # Chosen here, not left to Voltage, both because it requires a
        # client-supplied id and because it doubles as the handle for the
        # follow-up read below.
        payment_id = str(uuid.uuid4())
        async with self._client(10) as client:
            try:
                response = await client.post(
                    self._payments_path(),
                    json={
                        "id": payment_id,
                        "wallet_id": self._config.wallet_id,
                        "direction": "receive",
                        "currency": "btc",
                        "payment_kind": "bolt11",
                        "amount_msats": amount_sats * 1000,
                        "memo": memo,
                    },
                )
                self._check(response)
                # Confirmed against a real account: the create response
                # comes back 202 with an empty body, and the payment (and
                # its BOLT11 invoice) is generated asynchronously -- still
                # null moments later, not just on that first empty response.
                # A single follow-up read isn't reliably enough later than
                # the create call to have it; this polls briefly instead of
                # trusting any one read's timing. The payment resource nests
                # kind-specific fields (like the invoice string) under
                # `data`; everything else (id, status) sits at the top
                # level. `(... or {})` covers `data` being either absent or
                # explicitly null, both seen on a still-resolving payment.
                body = response.json() if response.content else {}
                payment_request = (body.get("data") or {}).get("payment_request")
                for _attempt in range(10):
                    if payment_request:
                        break
                    await asyncio.sleep(0.3)
                    follow_up = await client.get(self._payments_path(f"/{payment_id}"))
                    self._check(follow_up)
                    body = follow_up.json()
                    payment_request = (body.get("data") or {}).get("payment_request")
                if not payment_request:
                    raise LightningNodeError("invoice was not ready after waiting")
                return Invoice(
                    payment_request=payment_request,
                    payment_hash=body.get("id", payment_id),
                    amount_sats=amount_sats,
                )
            except LightningNodeError:
                raise
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not create invoice: {error}") from error

    async def invoice_status(self, payment_hash: str) -> InvoiceStatus:
        async with self._client(10) as client:
            try:
                response = await client.get(self._payments_path(f"/{payment_hash}"))
                self._check(response)
                body = response.json()
                # Confirmed live: a fresh receive payment's status is
                # "receiving", not yet a settled/paid state. The exact
                # terminal value ("received"? "completed"?) hasn't been
                # observed yet -- this covers the plausible spellings, and
                # whichever one Voltage actually uses will show up in the
                # /check response and can be confirmed then.
                settled = body.get("status") in ("completed", "succeeded", "settled", "received")
                amount_msats = (body.get("requested_amount") or {}).get("amount", 0)
                return InvoiceStatus(
                    settled=settled,
                    amount_sats=int(amount_msats) // 1000,
                )
            except LightningNodeError:
                raise
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not check invoice: {error}") from error

    async def decode_invoice(self, payment_request: str) -> DecodedInvoice:
        """Reads what an external BOLT11 invoice is actually for, before
        committing to paying it. Guessed to be a quote resource -- Voltage's
        docs list a separate "Quotes" section this hasn't been read yet --
        rather than the node-backed `decodepayreq` primitive, which a
        credit-backed wallet has no node to run itself.

        Mirrors payment creation's shape (client-generated `id`, async 202
        with a follow-up read, fields nested under `data`) since that's the
        pattern every other Voltage resource here has turned out to follow."""
        quote_id = str(uuid.uuid4())
        quotes_path = (
            f"/organizations/{self._config.organization_id}"
            f"/environments/{self._config.environment_id}/quotes"
        )
        async with self._client(10) as client:
            try:
                response = await client.post(
                    quotes_path,
                    json={
                        "id": quote_id,
                        "wallet_id": self._config.wallet_id,
                        "line_of_credit_id": self._config.line_of_credit_id,
                        "payment_request": payment_request,
                    },
                )
                self._check(response)
                body = response.json() if response.content else {}
                for _attempt in range(10):
                    if body.get("data") or body.get("amount_msats"):
                        break
                    await asyncio.sleep(0.3)
                    follow_up = await client.get(f"{quotes_path}/{quote_id}")
                    self._check(follow_up)
                    body = follow_up.json()
                data = body.get("data") or body
                return DecodedInvoice(
                    amount_sats=int(data.get("amount_msats", 0)) // 1000,
                    destination=data.get("destination", ""),
                    description=data.get("memo", data.get("description", "")),
                )
            except LightningNodeError:
                raise
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not decode invoice: {error}") from error

    async def pay_invoice(self, payment_request: str) -> PaymentResult:
        # Not yet exercised against a real send -- this mirrors the shape
        # confirmed for a receive payment (a client-chosen id, a 202 with an
        # empty body, kind-specific fields nested under `data`), on the
        # assumption the same envelope applies to both directions. The
        # first real withdrawal will confirm or correct this.
        payment_id = str(uuid.uuid4())
        async with self._client(30) as client:
            try:
                response = await client.post(
                    self._payments_path(),
                    json={
                        "id": payment_id,
                        "wallet_id": self._config.wallet_id,
                        "line_of_credit_id": self._config.line_of_credit_id,
                        "direction": "send",
                        "currency": "btc",
                        "payment_kind": "bolt11",
                        "payment_request": payment_request,
                    },
                )
                self._check(response)
                # Same asynchronous-creation shape confirmed for receive
                # payments, applied here too: poll briefly rather than
                # trusting a single follow-up read to have a status yet.
                body = response.json() if response.content else {}
                for _attempt in range(10):
                    if body.get("status"):
                        break
                    await asyncio.sleep(0.3)
                    follow_up = await client.get(self._payments_path(f"/{payment_id}"))
                    self._check(follow_up)
                    body = follow_up.json()
                if not body.get("status"):
                    raise LightningNodeError("payment result was not ready after waiting")
                if body.get("status") == "failed":
                    error_detail = body.get("error") or (body.get("data") or {}).get("error") or "payment failed"
                    raise LightningNodeError(error_detail)
                return PaymentResult(
                    payment_hash=body.get("id", payment_id),
                    fee_sats=int((body.get("data") or {}).get("fee_msats", 0)) // 1000,
                )
            except LightningNodeError:
                raise
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not pay invoice: {error}") from error


def rail_from_env() -> LightningRail | None:
    config = config_from_env()
    if config is None:
        return None
    return VoltagePaymentsRail(config)
