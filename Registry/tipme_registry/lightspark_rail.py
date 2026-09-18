"""Real Lightning movement via Lightspark's node-backed API.

## Why this exists, and how it fits alongside Voltage

`lightning_node.py`'s `LightningRail` protocol is the seam that makes this a
non-event: this is a second, independent implementation of the exact same
protocol (`create_invoice`/`invoice_status`/`decode_invoice`/`pay_invoice`),
built against a different provider, with none of the endpoints or the ledger
needing to change. `app.get_lightning_rail` picks whichever is configured,
preferring this one when both are.

Lightspark's model here is node-backed, not credit-backed: the registry
operates one Lightspark-hosted Lightning node (`REGISTRY_LIGHTSPARK_NODE_ID`),
the same way Voltage's *other* product works (see `lightning_node.py`'s
module docstring for that distinction). Per-user balances still live only in
the registry's own ledger, exactly as with Voltage -- Lightspark has no
concept of "TipMe user," only of payments in and out of one node.

## Sandbox-only capability

`simulate_test_payment` calls Lightspark's `create_test_mode_payment`
mutation, which only works against a sandbox/regtest node -- it fakes an
external wallet paying one of this node's own invoices, without needing a
real second party. This is not part of `LightningRail`: no real rail (this
one against mainnet, or Voltage) can satisfy it, and pretending otherwise
would be the same mistake as putting `receive`'s test-only concerns into
`WalletBackend` on the Swift side. It exists purely so the first end-to-end
proof of this rail doesn't need a second real wallet.

## Webhooks

Lightspark POSTs a signed event to a URL you register with them whenever a
payment reaches a terminal state (see `WebhookEvent` and
`REGISTRY_LIGHTSPARK_WEBHOOK_SECRET`). `verify_webhook` wraps the SDK's own
HMAC verification (`WebhookEvent.verify_and_parse`) -- see
`app.lightspark_webhook` for what it drives: completing a pending deposit
the moment the node reports the incoming payment finished, rather than
waiting for the client to poll `/check` again.

## Configuration

Reads ``REGISTRY_LIGHTSPARK_CLIENT_ID``, ``REGISTRY_LIGHTSPARK_CLIENT_SECRET``
and ``REGISTRY_LIGHTSPARK_NODE_ID`` (an API token and the node it operates,
both from the Lightspark dashboard). ``REGISTRY_LIGHTSPARK_WEBHOOK_SECRET``
is required for `verify_webhook` but not for payments themselves.
``REGISTRY_LIGHTSPARK_BASE_URL`` is optional, for pointing the SDK at a
non-default host. Until the first three are set, ``rail_from_env`` returns
``None`` and the deposit/withdraw endpoints fail closed with a 503, the same
convention every other rail in this codebase uses.
"""
from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass

from lightspark import CurrencyUnit, LightsparkSyncClient
from lightspark import WebhookEvent as LightsparkWebhookEvent
from lightspark.exceptions import LightsparkException
from lightspark.objects.IncomingPayment import IncomingPayment
from lightspark.objects.OutgoingPayment import OutgoingPayment
from lightspark.objects.TransactionStatus import TransactionStatus

from .lightning_node import DecodedInvoice, Invoice, InvoiceStatus, LightningNodeError, PaymentResult

_TERMINAL_STATUSES = {TransactionStatus.SUCCESS, TransactionStatus.FAILED,
                      TransactionStatus.CANCELLED, TransactionStatus.EXPIRED}


@dataclass(frozen=True)
class LightsparkConfig:
    client_id: str
    client_secret: str
    node_id: str
    webhook_secret: str | None
    base_url: str | None


def config_from_env() -> LightsparkConfig | None:
    client_id = os.environ.get("REGISTRY_LIGHTSPARK_CLIENT_ID")
    client_secret = os.environ.get("REGISTRY_LIGHTSPARK_CLIENT_SECRET")
    node_id = os.environ.get("REGISTRY_LIGHTSPARK_NODE_ID")
    if not (client_id and client_secret and node_id):
        return None
    return LightsparkConfig(
        client_id=client_id, client_secret=client_secret, node_id=node_id,
        webhook_secret=os.environ.get("REGISTRY_LIGHTSPARK_WEBHOOK_SECRET"),
        base_url=os.environ.get("REGISTRY_LIGHTSPARK_BASE_URL"),
    )


def _describe(error: LightsparkException) -> str:
    return ": ".join(str(part) for part in error.args) if error.args else str(error)


class LightsparkPaymentsRail:
    """Implements `lightning_node.LightningRail` against a single
    Lightspark-hosted node. See the module docstring for the node-backed vs
    credit-backed distinction and why per-user balances stay in the
    registry's own ledger regardless.

    `client` is injectable so tests can pass a fake satisfying the same
    handful of method calls this class actually makes, without touching the
    real SDK or a network -- the same seam `session: URLSession?` is on the
    Swift side.
    """

    def __init__(self, config: LightsparkConfig, client: LightsparkSyncClient | None = None):
        self._config = config
        self._client = client or LightsparkSyncClient(
            config.client_id, config.client_secret,
            base_url=config.base_url,
        )

    async def create_invoice(self, amount_sats: int, memo: str) -> Invoice:
        try:
            invoice = await asyncio.to_thread(
                self._client.create_invoice, self._config.node_id, amount_sats * 1000, memo,
            )
        except LightsparkException as error:
            raise LightningNodeError(f"could not create invoice: {_describe(error)}") from error
        return Invoice(
            payment_request=invoice.data.encoded_payment_request,
            payment_hash=invoice.data.payment_hash,
            amount_sats=amount_sats,
        )

    async def invoice_status(self, payment_hash: str) -> InvoiceStatus:
        try:
            invoice = await asyncio.to_thread(self._client.invoice_for_payment_hash, payment_hash)
        except LightsparkException as error:
            raise LightningNodeError(f"could not check invoice: {_describe(error)}") from error
        if invoice is None:
            raise LightningNodeError(f"no such invoice: {payment_hash}")
        settled = invoice.amount_paid is not None and invoice.amount_paid.original_value > 0
        amount_sats = (
            invoice.amount_paid.original_value if settled else invoice.data.amount.original_value
        ) // 1000
        return InvoiceStatus(settled=settled, amount_sats=amount_sats)

    async def decode_invoice(self, payment_request: str) -> DecodedInvoice:
        try:
            data = await asyncio.to_thread(self._client.get_decoded_payment_request, payment_request)
        except LightsparkException as error:
            raise LightningNodeError(f"could not decode invoice: {_describe(error)}") from error
        return DecodedInvoice(
            amount_sats=data.amount.original_value // 1000,
            destination=data.destination.id,
            description=data.memo or "",
        )

    async def pay_invoice(self, payment_request: str) -> PaymentResult:
        try:
            payment = await asyncio.to_thread(
                self._client.pay_invoice, self._config.node_id, payment_request,
                timeout_secs=60, maximum_fees_msats=10_000,
            )
            for _attempt in range(20):
                if payment.status in _TERMINAL_STATUSES:
                    break
                await asyncio.sleep(0.5)
                refreshed = await asyncio.to_thread(self._client.get_entity, payment.id, OutgoingPayment)
                if refreshed is None:
                    break
                payment = refreshed
        except LightsparkException as error:
            raise LightningNodeError(f"could not pay invoice: {_describe(error)}") from error
        if payment.status != TransactionStatus.SUCCESS:
            raise LightningNodeError(f"payment did not succeed: {payment.status.name}")
        return PaymentResult(payment_hash=payment.id, fee_sats=0)

    async def simulate_test_payment(self, payment_request: str, amount_sats: int | None = None) -> None:
        """Sandbox-only: makes this node's own invoice look paid, without a
        real second wallet. Raises `LightningNodeError` (most likely because
        this isn't actually a sandbox/regtest node) rather than silently
        doing nothing, since a caller relying on this to unblock a test
        should not be left guessing why nothing happened."""
        try:
            await asyncio.to_thread(
                self._client.create_test_mode_payment, self._config.node_id, payment_request,
                amount_sats * 1000 if amount_sats is not None else None,
            )
        except LightsparkException as error:
            raise LightningNodeError(
                f"could not simulate a test payment (is this a sandbox node?): {_describe(error)}"
            ) from error

    def verify_webhook(self, body: bytes, signature: str) -> LightsparkWebhookEvent:
        if not self._config.webhook_secret:
            raise LightningNodeError("REGISTRY_LIGHTSPARK_WEBHOOK_SECRET is not set")
        try:
            return LightsparkWebhookEvent.verify_and_parse(body, signature, self._config.webhook_secret)
        except ValueError as error:
            raise LightningNodeError(f"invalid webhook signature: {error}") from error

    def incoming_payment(self, payment_id: str) -> IncomingPayment | None:
        """Looks up an incoming payment by its own id, e.g. the `entity_id`
        a `FUNDS_RECEIVED`/`PAYMENT_FINISHED` webhook event carries. Not
        part of `LightningRail` -- webhook-driven completion is specific to
        rails that actually push events, which Voltage doesn't."""
        try:
            return self._client.get_entity(payment_id, IncomingPayment)
        except LightsparkException as error:
            raise LightningNodeError(f"could not look up payment: {_describe(error)}") from error


def rail_from_env() -> LightsparkPaymentsRail | None:
    config = config_from_env()
    if config is None:
        return None
    return LightsparkPaymentsRail(config)
