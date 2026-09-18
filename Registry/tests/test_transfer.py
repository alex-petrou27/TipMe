"""Internal transfers between two TipMe accounts' ledgers.

No rail, no monkeypatching -- this never touches Lightning or on-chain,
just two ledger_balances rows.
"""
from tipme_registry import app as app_module


def _signup(client, email, password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def test_transfer_moves_balance_between_two_accounts(client):
    sender = _signup(client, "sender@example.com").json()
    _signup(client, "recipient@example.com")

    storage = app_module.get_storage(app_module.get_settings())
    storage.adjust_balance(sender["user_id"], "bitcoin", 5000, reason="test_seed")

    response = client.post(
        "/v1/transfer",
        json={"to_email": "recipient@example.com", "asset": "bitcoin", "amount_minor": 2000},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 200
    assert {b["asset"]: b["balance_minor"] for b in response.json()["balances"]}["bitcoin"] == 3000

    recipient_token = client.post(
        "/v1/auth/login", json={"email": "recipient@example.com", "password": "correct horse battery"},
    ).json()["session_token"]
    recipient_me = client.get("/v1/me", headers=_headers(recipient_token)).json()
    assert {b["asset"]: b["balance_minor"] for b in recipient_me["balances"]}["bitcoin"] == 2000


def test_transfer_rejects_insufficient_balance_without_touching_either_side(client):
    sender = _signup(client, "sender@example.com").json()
    _signup(client, "recipient@example.com")

    response = client.post(
        "/v1/transfer",
        json={"to_email": "recipient@example.com", "asset": "bitcoin", "amount_minor": 2000},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 402

    sender_me = client.get("/v1/me", headers=_headers(sender["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in sender_me["balances"]}["bitcoin"] == 0


def test_transfer_rejects_an_unknown_recipient(client):
    sender = _signup(client, "sender@example.com").json()
    response = client.post(
        "/v1/transfer",
        json={"to_email": "nobody@example.com", "asset": "bitcoin", "amount_minor": 100},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 404


def test_transfer_rejects_transferring_to_yourself(client):
    sender = _signup(client, "sender@example.com").json()
    response = client.post(
        "/v1/transfer",
        json={"to_email": "sender@example.com", "asset": "bitcoin", "amount_minor": 100},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 400


def test_transfer_rejects_an_unknown_asset(client):
    sender = _signup(client, "sender@example.com").json()
    _signup(client, "recipient@example.com")
    response = client.post(
        "/v1/transfer",
        json={"to_email": "recipient@example.com", "asset": "dogecoin", "amount_minor": 100},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 400


def test_transfer_rejects_a_non_positive_amount(client):
    sender = _signup(client, "sender@example.com").json()
    _signup(client, "recipient@example.com")
    response = client.post(
        "/v1/transfer",
        json={"to_email": "recipient@example.com", "asset": "bitcoin", "amount_minor": 0},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 422
