"""Test doubles shared across Registry test modules."""
from __future__ import annotations

import json

from tipme_registry.bitcoin_chain import OnChainError, SendResult
from tipme_registry.grid_rail import GridCustomerHandle, GridError, GridTransferResult, WalletSession
from tipme_registry.lightning_node import DecodedInvoice, Invoice, InvoiceStatus, LightningNodeError, PaymentResult
from tipme_registry.turnkey_stamp import generate_keypair


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


class FakeGridRail:
    """In-memory Grid rail -- never touches a network or the real REST API.

    A test drives it directly: `fail_next_transfer`/`fail_next_fund` make
    the next call raise, `queue_webhook_event` primes what `verify_webhook`
    returns, exactly like `FakeLightningRail` above.
    """

    def __init__(self) -> None:
        self.currency = "USD"
        self._customers: dict[str, GridCustomerHandle] = {}
        self._accounts: dict[str, int] = {}
        self._transactions: dict[str, str] = {}
        self.funded: list[tuple[str, int]] = []
        self.transferred: list[tuple[str, str, int]] = []
        self.fail_next_ensure_customer = False
        self.fail_next_fund = False
        self.fail_next_transfer = False
        self.fail_next_wallet_session = False
        self.wallet_sessions_created: list[str] = []
        self._webhook_body: bytes | None = None
        self._counter = 0

    async def create_wallet_session(self, account_id: str) -> WalletSession:
        if self.fail_next_wallet_session:
            self.fail_next_wallet_session = False
            raise GridError("simulated wallet session failure")
        self.wallet_sessions_created.append(account_id)
        return WalletSession(
            account_id=account_id, keypair=generate_keypair(), expires_at="2099-01-01T00:00:00+00:00",
        )

    async def ensure_customer(self, platform_user_id: str, email: str) -> GridCustomerHandle:
        if self.fail_next_ensure_customer:
            self.fail_next_ensure_customer = False
            raise GridError("simulated customer provisioning failure")
        existing = self._customers.get(platform_user_id)
        if existing is not None:
            return existing
        self._counter += 1
        handle = GridCustomerHandle(
            customer_id=f"Customer:{self._counter}", account_id=f"InternalAccount:{self._counter}",
        )
        self._customers[platform_user_id] = handle
        self._accounts[handle.account_id] = 0
        return handle

    async def fund_sandbox(self, account_id: str, amount_minor: int) -> None:
        if self.fail_next_fund:
            self.fail_next_fund = False
            raise GridError("simulated funding failure")
        self.funded.append((account_id, amount_minor))
        self._accounts[account_id] = self._accounts.get(account_id, 0) + amount_minor

    async def transfer(
        self, source_account_id: str, destination_account_id: str, amount_minor: int,
        session: WalletSession,
    ) -> GridTransferResult:
        if self.fail_next_transfer:
            self.fail_next_transfer = False
            raise GridError("simulated transfer failure")
        self.transferred.append((source_account_id, destination_account_id, amount_minor))
        self._counter += 1
        transaction_id = f"Transaction:{self._counter}"
        self._transactions[transaction_id] = "COMPLETED"
        return GridTransferResult(
            quote_id=f"Quote:{self._counter}", transaction_id=transaction_id, status="COMPLETED",
        )

    async def get_transaction_status(self, transaction_id: str) -> str:
        status = self._transactions.get(transaction_id)
        if status is None:
            raise GridError(f"unknown transaction: {transaction_id}")
        return status

    def set_transaction_status(self, transaction_id: str, status: str) -> None:
        self._transactions[transaction_id] = status

    def queue_webhook_event(self, transaction_id: str, status: str) -> None:
        self._webhook_body = json.dumps({"transactionId": transaction_id, "status": status}).encode()

    def verify_webhook(self, body: bytes, signature: str) -> dict:
        if signature != "valid-signature":
            raise GridError("invalid webhook signature")
        if self._webhook_body is None:
            raise GridError("no webhook event queued")
        return json.loads(self._webhook_body)


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
