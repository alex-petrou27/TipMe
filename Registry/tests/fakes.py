"""Test doubles shared across Registry test modules."""
from __future__ import annotations

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
