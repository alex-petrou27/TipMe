"""Test doubles shared across Registry test modules."""
from __future__ import annotations

from lightspark import WebhookEventType

from tipme_registry.bitcoin_chain import OnChainError, SendResult
from tipme_registry.lightning_node import DecodedInvoice, Invoice, InvoiceStatus, LightningNodeError, PaymentResult


class FakeLightningRail:
    """In-memory Lightning rail -- never touches a network.

    A test drives it directly: `settle(payment_hash)` simulates an external
    wallet paying an invoice, `fail_next_payment` makes the next
    `pay_invoice` raise, exactly like `FakePaymentBackend` on the Swift side.
    """

    def __init__(self) -> None:
        self._invoices: dict[str, Invoice] = {}
        self._settled: set[str] = set()
        self._decodable: dict[str, DecodedInvoice] = {}
        self.fail_next_payment = False
        self.paid: list[str] = []
        self._counter = 0

    async def create_invoice(self, amount_sats: int, memo: str) -> Invoice:
        self._counter += 1
        payment_hash = f"fakehash{self._counter}"
        invoice = Invoice(
            payment_request=f"lnfake1{payment_hash}",
            payment_hash=payment_hash,
            amount_sats=amount_sats,
        )
        self._invoices[payment_hash] = invoice
        self._decodable[invoice.payment_request] = DecodedInvoice(
            amount_sats=amount_sats, destination="fake-node-pubkey", description=memo,
        )
        return invoice

    def settle(self, payment_hash: str) -> None:
        self._settled.add(payment_hash)

    async def invoice_status(self, payment_hash: str) -> InvoiceStatus:
        invoice = self._invoices.get(payment_hash)
        amount = invoice.amount_sats if invoice else 0
        return InvoiceStatus(settled=payment_hash in self._settled, amount_sats=amount)

    def register_external_invoice(self, payment_request: str, amount_sats: int) -> None:
        """Lets a withdrawal test decode an invoice this rail did not itself
        issue -- withdrawals pay invoices from *other* wallets, not ones
        this same fake created."""
        self._decodable[payment_request] = DecodedInvoice(
            amount_sats=amount_sats, destination="external-wallet-pubkey", description="",
        )

    async def decode_invoice(self, payment_request: str) -> DecodedInvoice:
        decoded = self._decodable.get(payment_request)
        if decoded is None:
            raise LightningNodeError("unknown test invoice")
        return decoded

    async def pay_invoice(self, payment_request: str) -> PaymentResult:
        if self.fail_next_payment:
            self.fail_next_payment = False
            raise LightningNodeError("simulated payment failure")
        if payment_request not in self._decodable:
            raise LightningNodeError("unknown test invoice")
        self.paid.append(payment_request)
        return PaymentResult(payment_hash=f"paid-{payment_request}", fee_sats=1)


class FakeIncomingPayment:
    def __init__(self, transaction_hash: str | None):
        self.transaction_hash = transaction_hash


class FakeWebhookEvent:
    def __init__(self, event_type: WebhookEventType, entity_id: str):
        self.event_type = event_type
        self.entity_id = entity_id


class FakeLightsparkRail(FakeLightningRail):
    """Adds the Lightspark-only extras (`simulate_test_payment`,
    `verify_webhook`, `incoming_payment`) on top of `FakeLightningRail`'s
    shared behaviour, so app-level tests can exercise the Lightspark-only
    endpoints without the real SDK or a network."""

    def __init__(self) -> None:
        super().__init__()
        self.simulated: list[str] = []
        self.fail_next_simulate = False
        self._webhook_event: FakeWebhookEvent | None = None
        self._incoming_payments: dict[str, FakeIncomingPayment] = {}

    async def simulate_test_payment(self, payment_request: str, amount_sats: int | None = None) -> None:
        if self.fail_next_simulate:
            self.fail_next_simulate = False
            raise LightningNodeError("simulated failure")
        self.simulated.append(payment_request)
        # Simulating a payment against one of our own invoices settles it,
        # the same way a real external wallet paying it would.
        for payment_hash, invoice in self._invoices.items():
            if invoice.payment_request == payment_request:
                self.settle(payment_hash)

    def queue_webhook_event(self, event_type: WebhookEventType, entity_id: str) -> None:
        self._webhook_event = FakeWebhookEvent(event_type, entity_id)

    def verify_webhook(self, body: bytes, signature: str) -> FakeWebhookEvent:
        if signature != "valid-signature":
            raise LightningNodeError("invalid webhook signature")
        if self._webhook_event is None:
            raise LightningNodeError("no webhook event queued")
        return self._webhook_event

    def register_incoming_payment(self, payment_id: str, transaction_hash: str | None) -> None:
        self._incoming_payments[payment_id] = FakeIncomingPayment(transaction_hash)

    def incoming_payment(self, payment_id: str) -> FakeIncomingPayment | None:
        return self._incoming_payments.get(payment_id)


class FakeOnChainRail:
    """In-memory on-chain rail -- never touches a network or a real wallet.

    A test drives it directly: `receive(address, sats)` simulates a
    confirmed on-chain payment landing at an address this rail issued,
    `fail_next_send` makes the next `send` raise.
    """

    def __init__(self) -> None:
        self._addresses: dict[int, str] = {}
        self._received: dict[str, int] = {}
        self.fail_next_send = False
        self.sent: list[tuple[str, int]] = []

    async def deposit_address(self, index: int) -> str:
        return self._addresses.setdefault(index, f"tb1qfakeaddress{index}")

    def receive(self, address: str, amount_sats: int) -> None:
        self._received[address] = self._received.get(address, 0) + amount_sats

    async def confirmed_received_sats(self, address: str) -> int:
        return self._received.get(address, 0)

    async def send(self, to_address: str, amount_sats: int,
                   known_index_count: int, change_index: int) -> SendResult:
        if self.fail_next_send:
            self.fail_next_send = False
            raise OnChainError("simulated broadcast failure")
        self.sent.append((to_address, amount_sats))
        return SendResult(txid=f"fake-txid-{len(self.sent)}", fee_sats=200, change_index=None)
