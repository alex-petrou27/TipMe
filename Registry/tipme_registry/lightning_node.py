"""Real Lightning movement, via a hosted LND node (Voltage).

This is a money-transmission integration for the *test-with-your-own-funds*
phase of the custodial pivot -- deliberately scoped to Lightning only for now.
On-chain Bitcoin sends/receives and USDT/Tron are separate follow-ups, each
its own protocol and its own real-money testing pass.

## Why Voltage, and why this stays behind a protocol

Voltage hosts a real LND node -- unlike a fully custodial API, the operator
still holds the node's keys, but does not have to run node infrastructure.
`LightningRail` is the seam: `VoltageLightningRail` below is one
implementation of it, `FakeLightningRail` (in tests) is another that never
touches a network. Swapping to a different provider, or to a fully custodial
account-based one later, means writing a new class against this same
protocol -- nothing above it (the ledger, the endpoints, the app) changes.
This is the same seam `PaymentBackend` already is for the tip-sending path.

## Honesty about what is verified here

`VoltageLightningRail` is written from LND's own documented REST API
(api.lightning.community) -- it has **not** been exercised against a real
node, because no Voltage account exists yet. Expect the same kind of
iteration the Instagram title-parsing fix needed: get a real node, try a real
deposit, and fix whatever field name or status code turns out to differ from
what the docs say. Everything else in this module (the protocol, the ledger
wiring, `FakeLightningRail`) does not depend on that being exactly right and
is fully tested today.

## Configuration

Reads ``REGISTRY_VOLTAGE_REST_URL`` (e.g.
``https://<node-id>.m.voltageapp.io``) and ``REGISTRY_VOLTAGE_MACAROON_HEX``
(a hex-encoded macaroon -- Voltage's dashboard offers an invoice+payments-
scoped one; avoid the full admin macaroon, since this process only ever
needs to create/pay invoices, never to manage the node itself). Until both
are set, ``rail_from_env`` returns ``None`` and the deposit/withdraw
endpoints fail closed with a 503, the same convention ``oauth.config_for``
already uses for Instagram/TikTok.

Both names carry the ``REGISTRY_`` prefix deliberately:
``Scripts/make-xcconfig.sh`` strips exactly that prefix from what reaches the
iOS app bundle, so a differently-named credential here would ship inside the
compiled app -- a real Lightning node macaroon, extractable by anyone who
decompiles the binary.
"""
from __future__ import annotations

import base64
import os
from dataclasses import dataclass
from typing import Protocol

import httpx


class LightningNodeError(Exception):
    """The node was reached but the call did not succeed -- an invoice that
    doesn't exist, a payment that failed to route, a malformed request."""


@dataclass(frozen=True)
class LightningNodeConfig:
    rest_url: str
    macaroon_hex: str


def config_from_env() -> LightningNodeConfig | None:
    rest_url = os.environ.get("REGISTRY_VOLTAGE_REST_URL")
    macaroon = os.environ.get("REGISTRY_VOLTAGE_MACAROON_HEX")
    if not (rest_url and macaroon):
        return None
    return LightningNodeConfig(rest_url=rest_url.rstrip("/"), macaroon_hex=macaroon)


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
    """What the deposit/withdraw endpoints need from a Lightning node."""

    async def create_invoice(self, amount_sats: int, memo: str) -> Invoice: ...

    async def invoice_status(self, payment_hash: str) -> InvoiceStatus: ...

    async def decode_invoice(self, payment_request: str) -> DecodedInvoice: ...

    async def pay_invoice(self, payment_request: str) -> PaymentResult: ...


class VoltageLightningRail:
    """Talks to a hosted LND node's REST API. See the module docstring --
    the exact request/response shapes here are unverified against a real
    node and are the first thing to check if this starts throwing."""

    def __init__(self, config: LightningNodeConfig):
        self._config = config

    def _client(self, timeout: float) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=self._config.rest_url,
            timeout=timeout,
            headers={"Grpc-Metadata-macaroon": self._config.macaroon_hex},
        )

    async def create_invoice(self, amount_sats: int, memo: str) -> Invoice:
        async with self._client(10) as client:
            try:
                response = await client.post(
                    "/v1/invoices", json={"value": str(amount_sats), "memo": memo},
                )
                response.raise_for_status()
                body = response.json()
                return Invoice(
                    payment_request=body["payment_request"],
                    payment_hash=_b64_to_hex(body["r_hash"]),
                    amount_sats=amount_sats,
                )
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not create invoice: {error}") from error

    async def invoice_status(self, payment_hash: str) -> InvoiceStatus:
        async with self._client(10) as client:
            try:
                response = await client.get(f"/v1/invoice/{payment_hash}")
                response.raise_for_status()
                body = response.json()
                return InvoiceStatus(
                    settled=bool(body.get("settled", False)),
                    amount_sats=int(body.get("value", 0)),
                )
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not check invoice: {error}") from error

    async def decode_invoice(self, payment_request: str) -> DecodedInvoice:
        async with self._client(10) as client:
            try:
                response = await client.get(f"/v1/payreq/{payment_request}")
                response.raise_for_status()
                body = response.json()
                return DecodedInvoice(
                    amount_sats=int(body.get("num_satoshis", 0)),
                    destination=body.get("destination", ""),
                    description=body.get("description", ""),
                )
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not decode invoice: {error}") from error

    async def pay_invoice(self, payment_request: str) -> PaymentResult:
        async with self._client(30) as client:
            try:
                response = await client.post(
                    "/v1/channels/transactions",
                    json={"payment_request": payment_request},
                )
                response.raise_for_status()
                body = response.json()
                if body.get("payment_error"):
                    raise LightningNodeError(body["payment_error"])
                route = body.get("payment_route") or {}
                return PaymentResult(
                    payment_hash=_b64_to_hex(body["payment_hash"]) if body.get("payment_hash") else "",
                    fee_sats=int(route.get("total_fees", 0)),
                )
            except (httpx.HTTPError, KeyError, ValueError) as error:
                raise LightningNodeError(f"could not pay invoice: {error}") from error


def rail_from_env() -> LightningRail | None:
    config = config_from_env()
    if config is None:
        return None
    return VoltageLightningRail(config)


def _b64_to_hex(value: str) -> str:
    return base64.b64decode(value).hex()
