"""The Lightspark rail's own logic, exercised against a fake client that
satisfies exactly the handful of SDK calls `LightsparkPaymentsRail` actually
makes -- never a real network call, same convention as every other rail's
tests in this codebase. No pytest-asyncio in this suite (see
`test_bitcoin_chain.py`'s own note) -- async calls are driven with
`asyncio.run(...)` from plain sync tests.

Webhook signature verification (`verify_webhook`) is the one thing here
backed by real, unfaked SDK logic (`WebhookEvent.verify_and_parse`'s HMAC
check) -- that's cheap to exercise for real and is exactly the kind of
security-relevant code worth not mocking away.
"""
import asyncio
import hashlib
import hmac
import json
from datetime import datetime, timezone

import pytest
from lightspark.exceptions import LightsparkException
from lightspark.objects.CurrencyAmount import CurrencyAmount
from lightspark.objects.CurrencyUnit import CurrencyUnit
from lightspark.objects.Invoice import Invoice
from lightspark.objects.InvoiceData import InvoiceData
from lightspark.objects.Node import Node
from lightspark.objects.OutgoingPayment import OutgoingPayment
from lightspark.objects.PaymentRequestStatus import PaymentRequestStatus
from lightspark.objects.TransactionStatus import TransactionStatus

from tipme_registry import lightspark_rail

_NOW = datetime(2026, 1, 1, tzinfo=timezone.utc)


def _msat_amount(value: int) -> CurrencyAmount:
    return CurrencyAmount(
        requester=None, original_value=value, original_unit=CurrencyUnit.MILLISATOSHI,
        preferred_currency_unit=CurrencyUnit.USD, preferred_currency_value_rounded=0,
        preferred_currency_value_approx=0.0,
    )


def _node(node_id: str = "node-abc") -> Node:
    return Node(requester=None, id=node_id, typename="LightsparkNode", created_at=_NOW, updated_at=_NOW,
                alias=None, bitcoin_network=None, color=None, conductivity=None,
                display_name="", public_key=None)


def _invoice(payment_hash: str, amount_msats: int, encoded="lnbc1mock",
             amount_paid: CurrencyAmount | None = None) -> Invoice:
    data = InvoiceData(
        requester=None, encoded_payment_request=encoded, bitcoin_network=None, typename="InvoiceData",
        payment_hash=payment_hash, amount=_msat_amount(amount_msats), created_at=_NOW, expires_at=_NOW,
        memo="a memo", destination=_node(),
    )
    return Invoice(requester=None, id=f"invoice-{payment_hash}", created_at=_NOW, updated_at=_NOW,
                   typename="Invoice", data=data, status=PaymentRequestStatus.OPEN, amount_paid=amount_paid)


def _outgoing_payment(payment_id: str, status: TransactionStatus) -> OutgoingPayment:
    return OutgoingPayment(
        requester=None, id=payment_id, created_at=_NOW, updated_at=_NOW, typename="OutgoingPayment",
        status=status, resolved_at=None, amount=_msat_amount(3_000_000), transaction_hash="hash-abc",
        is_uma=False, origin_id="node-abc", destination_id=None, fees=None, payment_request_data=None,
        failure_reason=None, failure_message=None, uma_post_transaction_data=None, payment_preimage=None,
        is_internal_payment=True, idempotency_key=None,
    )


class FakeLightsparkClient:
    """Duck-types exactly the `LightsparkSyncClient` methods `LightsparkPaymentsRail` calls."""

    def __init__(self):
        self.create_invoice_calls = []
        self.pay_invoice_calls = []
        self.create_test_mode_payment_calls = []
        self._invoice_to_return: Invoice | None = None
        self._outgoing_payment_sequence: list[OutgoingPayment] = []
        self._decoded_to_return: InvoiceData | None = None
        self.raise_on_pay: LightsparkException | None = None
        self.raise_on_test_payment: LightsparkException | None = None

    def create_invoice(self, node_id, amount_msats, memo=None, invoice_type=None, expiry_secs=None):
        self.create_invoice_calls.append((node_id, amount_msats, memo))
        return _invoice("hash-abc", amount_msats)

    def invoice_for_payment_hash(self, payment_hash):
        return self._invoice_to_return

    def get_decoded_payment_request(self, encoded_payment_request):
        return self._decoded_to_return

    def pay_invoice(self, node_id, encoded_invoice, timeout_secs, maximum_fees_msats,
                    amount_msats=None, idempotency_key=None):
        self.pay_invoice_calls.append(encoded_invoice)
        if self.raise_on_pay:
            raise self.raise_on_pay
        return self._outgoing_payment_sequence[0]

    def get_entity(self, entity_id, entity_class):
        # Pops the next payment in the polling sequence, simulating a
        # payment that starts PENDING and later becomes terminal.
        if len(self._outgoing_payment_sequence) > 1:
            self._outgoing_payment_sequence.pop(0)
        return self._outgoing_payment_sequence[0]

    def create_test_mode_payment(self, local_node_id, encoded_invoice, amount_msats):
        self.create_test_mode_payment_calls.append((local_node_id, encoded_invoice, amount_msats))
        if self.raise_on_test_payment:
            raise self.raise_on_test_payment


def _config(webhook_secret="whsecret") -> lightspark_rail.LightsparkConfig:
    return lightspark_rail.LightsparkConfig(
        client_id="cid", client_secret="csecret", node_id="node-abc",
        webhook_secret=webhook_secret, base_url=None,
    )


# --- config_from_env ---

def _clear(monkeypatch):
    for name in ("REGISTRY_LIGHTSPARK_CLIENT_ID", "REGISTRY_LIGHTSPARK_CLIENT_SECRET",
                 "REGISTRY_LIGHTSPARK_NODE_ID", "REGISTRY_LIGHTSPARK_WEBHOOK_SECRET",
                 "REGISTRY_LIGHTSPARK_BASE_URL"):
        monkeypatch.delenv(name, raising=False)


def test_config_from_env_is_none_when_unset(monkeypatch):
    _clear(monkeypatch)
    assert lightspark_rail.config_from_env() is None


def test_config_from_env_requires_all_three_core_values(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("REGISTRY_LIGHTSPARK_CLIENT_ID", "cid")
    monkeypatch.setenv("REGISTRY_LIGHTSPARK_CLIENT_SECRET", "csecret")
    assert lightspark_rail.config_from_env() is None


def test_config_from_env_webhook_secret_is_optional(monkeypatch):
    _clear(monkeypatch)
    monkeypatch.setenv("REGISTRY_LIGHTSPARK_CLIENT_ID", "cid")
    monkeypatch.setenv("REGISTRY_LIGHTSPARK_CLIENT_SECRET", "csecret")
    monkeypatch.setenv("REGISTRY_LIGHTSPARK_NODE_ID", "node-abc")
    config = lightspark_rail.config_from_env()
    assert config is not None
    assert config.webhook_secret is None


def test_rail_from_env_is_none_when_unconfigured(monkeypatch):
    _clear(monkeypatch)
    assert lightspark_rail.rail_from_env() is None


# --- create_invoice ---

def test_create_invoice_returns_the_encoded_request_and_hash():
    client = FakeLightsparkClient()
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    invoice = asyncio.run(rail.create_invoice(1000, "a memo"))

    assert invoice.payment_request == "lnbc1mock"
    assert invoice.payment_hash == "hash-abc"
    assert invoice.amount_sats == 1000
    assert client.create_invoice_calls == [("node-abc", 1_000_000, "a memo")]


# --- invoice_status ---

def test_invoice_status_is_unsettled_with_no_amount_paid():
    client = FakeLightsparkClient()
    client._invoice_to_return = _invoice("hash-abc", 1_000_000, amount_paid=None)
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    status = asyncio.run(rail.invoice_status("hash-abc"))
    assert status.settled is False
    assert status.amount_sats == 1000


def test_invoice_status_is_settled_once_amount_paid_is_set():
    client = FakeLightsparkClient()
    client._invoice_to_return = _invoice("hash-abc", 1_000_000, amount_paid=_msat_amount(1_000_000))
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    status = asyncio.run(rail.invoice_status("hash-abc"))
    assert status.settled is True
    assert status.amount_sats == 1000


def test_invoice_status_raises_for_an_unknown_hash():
    client = FakeLightsparkClient()
    client._invoice_to_return = None
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    with pytest.raises(lightspark_rail.LightningNodeError):
        asyncio.run(rail.invoice_status("no-such-hash"))


# --- decode_invoice ---

def test_decode_invoice_maps_amount_and_destination():
    client = FakeLightsparkClient()
    client._decoded_to_return = InvoiceData(
        requester=None, encoded_payment_request="lnbc-external", bitcoin_network=None,
        typename="InvoiceData", payment_hash="external-hash", amount=_msat_amount(2_000_000),
        created_at=_NOW, expires_at=_NOW, memo="pay me", destination=_node("their-node"),
    )
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    decoded = asyncio.run(rail.decode_invoice("lnbc-external"))
    assert decoded.amount_sats == 2000
    assert decoded.destination == "their-node"
    assert decoded.description == "pay me"


# --- pay_invoice ---

def test_pay_invoice_returns_immediately_when_already_terminal():
    client = FakeLightsparkClient()
    client._outgoing_payment_sequence = [_outgoing_payment("pay-1", TransactionStatus.SUCCESS)]
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    result = asyncio.run(rail.pay_invoice("lnbc-external"))
    assert result.payment_hash == "pay-1"
    assert client.pay_invoice_calls == ["lnbc-external"]


def test_pay_invoice_polls_until_terminal(monkeypatch):
    monkeypatch.setattr(lightspark_rail.asyncio, "sleep", _instant_sleep)

    client = FakeLightsparkClient()
    client._outgoing_payment_sequence = [
        _outgoing_payment("pay-1", TransactionStatus.PENDING),
        _outgoing_payment("pay-1", TransactionStatus.SUCCESS),
    ]
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    result = asyncio.run(rail.pay_invoice("lnbc-external"))
    assert result.payment_hash == "pay-1"


async def _instant_sleep(_seconds):
    return None


def test_pay_invoice_raises_when_the_payment_fails(monkeypatch):
    monkeypatch.setattr(lightspark_rail.asyncio, "sleep", _instant_sleep)

    client = FakeLightsparkClient()
    client._outgoing_payment_sequence = [_outgoing_payment("pay-1", TransactionStatus.FAILED)]
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    with pytest.raises(lightspark_rail.LightningNodeError):
        asyncio.run(rail.pay_invoice("lnbc-external"))


def test_pay_invoice_wraps_sdk_exceptions():
    client = FakeLightsparkClient()
    client.raise_on_pay = LightsparkException("INSUFFICIENT_BALANCE", "not enough funds")
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    with pytest.raises(lightspark_rail.LightningNodeError, match="not enough funds"):
        asyncio.run(rail.pay_invoice("lnbc-external"))


# --- simulate_test_payment ---

def test_simulate_test_payment_calls_through_to_the_sdk():
    client = FakeLightsparkClient()
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    asyncio.run(rail.simulate_test_payment("lnbc-own-invoice", amount_sats=500))
    assert client.create_test_mode_payment_calls == [("node-abc", "lnbc-own-invoice", 500_000)]


def test_simulate_test_payment_wraps_sdk_exceptions():
    client = FakeLightsparkClient()
    client.raise_on_test_payment = LightsparkException("NOT_SANDBOX", "this node is not a sandbox node")
    rail = lightspark_rail.LightsparkPaymentsRail(_config(), client=client)

    with pytest.raises(lightspark_rail.LightningNodeError, match="sandbox"):
        asyncio.run(rail.simulate_test_payment("lnbc-own-invoice"))


# --- verify_webhook (real HMAC verification, no fake) ---

def test_verify_webhook_accepts_a_correctly_signed_event():
    client = FakeLightsparkClient()
    rail = lightspark_rail.LightsparkPaymentsRail(_config(webhook_secret="whsecret"), client=client)

    body = json.dumps({
        "event_type": "FUNDS_RECEIVED", "event_id": "evt-1",
        "timestamp": "2026-01-01T00:00:00+00:00", "entity_id": "payment-1",
    }).encode("utf-8")
    signature = hmac.new(b"whsecret", msg=body, digestmod=hashlib.sha256).hexdigest()

    event = rail.verify_webhook(body, signature)
    assert event.entity_id == "payment-1"


def test_verify_webhook_rejects_a_bad_signature():
    client = FakeLightsparkClient()
    rail = lightspark_rail.LightsparkPaymentsRail(_config(webhook_secret="whsecret"), client=client)

    with pytest.raises(lightspark_rail.LightningNodeError):
        rail.verify_webhook(b'{"event_type": "FUNDS_RECEIVED"}', "not-a-real-signature")


def test_verify_webhook_requires_a_configured_secret():
    client = FakeLightsparkClient()
    rail = lightspark_rail.LightsparkPaymentsRail(_config(webhook_secret=None), client=client)

    with pytest.raises(lightspark_rail.LightningNodeError, match="WEBHOOK_SECRET"):
        rail.verify_webhook(b"{}", "sig")
