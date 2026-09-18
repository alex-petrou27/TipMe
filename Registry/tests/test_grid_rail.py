"""Unit tests for grid_rail.py against a mocked HTTP transport -- never a
real network call. See bitcoin_chain.py's tests for the same idea applied
to a different rail.
"""
import asyncio
import base64
import json

import httpx
import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from tipme_registry.grid_rail import GridConfig, GridError, GridRail


def _config(base_url: str = "https://grid.test") -> GridConfig:
    return GridConfig(
        client_id="test-id", client_secret="test-secret",
        webhook_public_key_pem=None, base_url=base_url, currency="USD",
    )


def _rail(handler) -> GridRail:
    transport = httpx.MockTransport(handler)
    client = httpx.AsyncClient(
        base_url="https://grid.test", transport=transport, auth=("test-id", "test-secret"),
    )
    return GridRail(_config(), client=client)


def test_ensure_customer_returns_an_existing_customer_without_creating_one():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/customers":
            assert request.url.params["platformCustomerId"] == "user-1"
            return httpx.Response(200, json={"data": [{"id": "Customer:1"}]})
        if request.url.path == "/customers/internal-accounts":
            assert request.url.params["customerId"] == "Customer:1"
            return httpx.Response(200, json={"data": [
                {"id": "InternalAccount:1", "type": "INTERNAL_FIAT",
                 "totalBalance": {"currency": {"code": "USD"}}},
            ]})
        raise AssertionError(f"unexpected request: {request.url}")

    rail = _rail(handler)
    handle = asyncio.run(rail.ensure_customer("user-1", "user1@example.com"))
    assert handle.customer_id == "Customer:1"
    assert handle.account_id == "InternalAccount:1"


def test_ensure_customer_creates_one_when_none_exists():
    created = {}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/customers" and request.method == "GET":
            return httpx.Response(200, json={"data": []})
        if request.url.path == "/customers" and request.method == "POST":
            body = json.loads(request.content)
            created.update(body)
            assert body["customerType"] == "INDIVIDUAL"
            assert body["platformCustomerId"] == "user-2"
            return httpx.Response(201, json={"id": "Customer:2"})
        if request.url.path == "/customers/internal-accounts":
            return httpx.Response(200, json={"data": [
                {"id": "InternalAccount:2", "type": "INTERNAL_FIAT",
                 "totalBalance": {"currency": {"code": "USD"}}},
            ]})
        raise AssertionError(f"unexpected request: {request.url}")

    rail = _rail(handler)
    handle = asyncio.run(rail.ensure_customer("user-2", "user2@example.com"))
    assert handle.customer_id == "Customer:2"
    assert handle.account_id == "InternalAccount:2"
    assert created["email"] == "user2@example.com"


def test_ensure_customer_raises_when_no_matching_internal_account_exists():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/customers":
            return httpx.Response(200, json={"data": [{"id": "Customer:3"}]})
        if request.url.path == "/customers/internal-accounts":
            return httpx.Response(200, json={"data": []})
        raise AssertionError(f"unexpected request: {request.url}")

    rail = _rail(handler)
    with pytest.raises(GridError):
        asyncio.run(rail.ensure_customer("user-3", "user3@example.com"))


def test_fund_sandbox_posts_the_amount():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["path"] = request.url.path
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"id": "InternalAccount:1"})

    rail = _rail(handler)
    asyncio.run(rail.fund_sandbox("InternalAccount:1", 500))
    assert seen["path"] == "/sandbox/internal-accounts/InternalAccount:1/fund"
    assert seen["body"] == {"amount": 500}


def test_transfer_creates_and_immediately_executes_a_quote():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/quotes"
        body = json.loads(request.content)
        assert body["source"] == {"sourceType": "ACCOUNT", "accountId": "InternalAccount:1"}
        assert body["destination"] == {"destinationType": "ACCOUNT", "accountId": "InternalAccount:2"}
        assert body["lockedCurrencyAmount"] == 500
        assert body["immediatelyExecute"] is True
        return httpx.Response(201, json={
            "id": "Quote:1", "status": "COMPLETED", "transactionId": "Transaction:1",
        })

    rail = _rail(handler)
    result = asyncio.run(rail.transfer("InternalAccount:1", "InternalAccount:2", 500))
    assert result.quote_id == "Quote:1"
    assert result.transaction_id == "Transaction:1"
    assert result.status == "COMPLETED"


def test_get_transaction_status_returns_the_status_field():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/transactions/Transaction:1"
        return httpx.Response(200, json={"id": "Transaction:1", "status": "PENDING"})

    rail = _rail(handler)
    status = asyncio.run(rail.get_transaction_status("Transaction:1"))
    assert status == "PENDING"


def test_a_non_2xx_response_raises_grid_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, text="Unauthorized")

    rail = _rail(handler)
    with pytest.raises(GridError):
        asyncio.run(rail.get_transaction_status("Transaction:1"))


def test_verify_webhook_accepts_a_correctly_signed_body():
    private_key = ec.generate_private_key(ec.SECP256R1())
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()

    body = b'{"transactionId": "Transaction:1", "status": "COMPLETED"}'
    signature = private_key.sign(body, ec.ECDSA(hashes.SHA256()))
    signature_b64 = base64.b64encode(signature).decode()

    rail = GridRail(GridConfig(
        client_id="id", client_secret="secret", webhook_public_key_pem=public_pem,
        base_url="https://grid.test", currency="USD",
    ), client=httpx.AsyncClient())

    event = rail.verify_webhook(body, signature_b64)
    assert event == {"transactionId": "Transaction:1", "status": "COMPLETED"}


def test_verify_webhook_rejects_a_bad_signature():
    private_key = ec.generate_private_key(ec.SECP256R1())
    public_pem = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()
    other_key = ec.generate_private_key(ec.SECP256R1())

    body = b'{"transactionId": "Transaction:1", "status": "COMPLETED"}'
    wrong_signature = other_key.sign(body, ec.ECDSA(hashes.SHA256()))
    signature_b64 = base64.b64encode(wrong_signature).decode()

    rail = GridRail(GridConfig(
        client_id="id", client_secret="secret", webhook_public_key_pem=public_pem,
        base_url="https://grid.test", currency="USD",
    ), client=httpx.AsyncClient())

    with pytest.raises(GridError):
        rail.verify_webhook(body, signature_b64)


def test_verify_webhook_fails_closed_without_a_configured_public_key():
    rail = GridRail(_config(), client=httpx.AsyncClient())
    with pytest.raises(GridError):
        rail.verify_webhook(b"{}", "irrelevant")
