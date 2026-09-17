"""Lightning deposit/withdraw against the custodial ledger.

Never talks to a real Voltage/LND node — `lightning_node.rail_from_env` is
monkeypatched to return `FakeLightningRail`, the same convention
`test_oauth.py` uses for `oauth.config_for`.
"""
from tipme_registry import app as app_module
from tipme_registry import lightning_node

from fakes import FakeLightningRail


def _signup(client, email="alex@example.com", password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _authed(client, monkeypatch):
    rail = FakeLightningRail()
    monkeypatch.setattr(lightning_node, "rail_from_env", lambda: rail)
    token = _signup(client).json()["session_token"]
    return token, rail


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _deposit_and_settle(client, token, rail, amount_sats=5000):
    payment_hash = client.post(
        "/v1/deposit/lightning", json={"amount_sats": amount_sats}, headers=_headers(token),
    ).json()["payment_hash"]
    rail.settle(payment_hash)
    client.post(f"/v1/deposit/lightning/{payment_hash}/check", headers=_headers(token))


# --- Configuration ---

def test_deposit_fails_closed_when_not_configured(client, monkeypatch):
    monkeypatch.setattr(lightning_node, "rail_from_env", lambda: None)
    token = _signup(client).json()["session_token"]
    response = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token))
    assert response.status_code == 503


def test_withdraw_fails_closed_when_not_configured(client, monkeypatch):
    monkeypatch.setattr(lightning_node, "rail_from_env", lambda: None)
    token = _signup(client).json()["session_token"]
    response = client.post("/v1/withdraw/lightning", json={"payment_request": "x"}, headers=_headers(token))
    assert response.status_code == 503


# --- Deposits ---

def test_deposit_creates_an_invoice_without_crediting_anything(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    response = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["amount_sats"] == 1000
    assert body["payment_request"]
    assert body["payment_hash"]

    me = client.get("/v1/me", headers=_headers(token)).json()
    assert {b["asset"]: b["balance_minor"] for b in me["balances"]} == {"bitcoin": 0, "usdt": 0}


def test_deposit_rejects_amounts_below_the_dust_floor(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    response = client.post("/v1/deposit/lightning", json={"amount_sats": 1}, headers=_headers(token))
    assert response.status_code == 422


def test_checking_an_unsettled_deposit_reports_pending_and_credits_nothing(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    payment_hash = client.post(
        "/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token),
    ).json()["payment_hash"]

    response = client.post(f"/v1/deposit/lightning/{payment_hash}/check", headers=_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "pending"
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 0


def test_checking_a_settled_deposit_credits_the_ledger_exactly_once(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    payment_hash = client.post(
        "/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token),
    ).json()["payment_hash"]

    rail.settle(payment_hash)
    first = client.post(f"/v1/deposit/lightning/{payment_hash}/check", headers=_headers(token))
    assert first.status_code == 200
    body = first.json()
    assert body["status"] == "completed"
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 1000

    # A repeated check (the app polling, or a retried request) must not
    # credit the ledger a second time for the same payment.
    second = client.post(f"/v1/deposit/lightning/{payment_hash}/check", headers=_headers(token))
    assert {b["asset"]: b["balance_minor"] for b in second.json()["balances"]}["bitcoin"] == 1000


def test_deposit_check_is_scoped_to_the_owning_user(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    payment_hash = client.post(
        "/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token),
    ).json()["payment_hash"]

    other_token = _signup(client, email="other@example.com").json()["session_token"]
    response = client.post(f"/v1/deposit/lightning/{payment_hash}/check", headers=_headers(other_token))
    assert response.status_code == 404


def test_checking_an_unknown_payment_hash_is_a_404(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    response = client.post("/v1/deposit/lightning/not-a-real-hash/check", headers=_headers(token))
    assert response.status_code == 404


# --- Withdrawals ---

def test_withdrawal_pays_a_real_invoice_and_debits_the_balance(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_settle(client, token, rail, amount_sats=5000)

    rail.register_external_invoice("lnbc-external-invoice", amount_sats=2000)
    response = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "lnbc-external-invoice"}, headers=_headers(token),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["amount_sats"] == 2000
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 3000
    assert "lnbc-external-invoice" in rail.paid


def test_withdrawal_refunds_the_balance_when_payment_fails(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_settle(client, token, rail, amount_sats=5000)

    rail.register_external_invoice("lnbc-external-invoice", amount_sats=2000)
    rail.fail_next_payment = True
    response = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "lnbc-external-invoice"}, headers=_headers(token),
    )
    assert response.status_code == 502

    me = client.get("/v1/me", headers=_headers(token)).json()
    assert {b["asset"]: b["balance_minor"] for b in me["balances"]}["bitcoin"] == 5000


def test_withdrawal_rejects_insufficient_balance_without_attempting_payment(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    rail.register_external_invoice("lnbc-external-invoice", amount_sats=2000)

    response = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "lnbc-external-invoice"}, headers=_headers(token),
    )
    assert response.status_code == 402
    assert rail.paid == []


def test_withdrawal_rejects_an_unreadable_invoice(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    response = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "garbage"}, headers=_headers(token),
    )
    assert response.status_code == 400


def test_withdrawal_rejects_amounts_below_the_dust_floor(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_settle(client, token, rail, amount_sats=5000)
    rail.register_external_invoice("lnbc-tiny", amount_sats=1)

    response = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "lnbc-tiny"}, headers=_headers(token),
    )
    assert response.status_code == 400


def test_the_same_invoice_cannot_be_paid_twice(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_settle(client, token, rail, amount_sats=5000)
    rail.register_external_invoice("lnbc-external-invoice", amount_sats=2000)

    first = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "lnbc-external-invoice"}, headers=_headers(token),
    )
    assert first.status_code == 200

    second = client.post(
        "/v1/withdraw/lightning", json={"payment_request": "lnbc-external-invoice"}, headers=_headers(token),
    )
    assert second.status_code == 409


# --- Storage, directly ---

def test_complete_deposit_if_pending_is_idempotent(client, monkeypatch):
    storage = app_module.get_storage(app_module.get_settings())
    token = _signup(client).json()["session_token"]
    user_id = client.get("/v1/me", headers=_headers(token)).json()["user_id"]

    storage.create_pending_deposit(
        user_id=user_id, asset="bitcoin", method="lightning_invoice",
        external_reference="hash-1", amount_minor=1000,
    )

    first = storage.complete_deposit_if_pending("lightning_invoice", "hash-1", reason="lightning_deposit")
    assert first is not None
    assert first.status == "completed"
    assert storage.get_balances(user_id)["bitcoin"] == 1000

    second = storage.complete_deposit_if_pending("lightning_invoice", "hash-1", reason="lightning_deposit")
    assert second is None
    assert storage.get_balances(user_id)["bitcoin"] == 1000


def test_complete_deposit_if_pending_returns_none_for_an_unknown_reference(client):
    storage = app_module.get_storage(app_module.get_settings())
    assert storage.complete_deposit_if_pending("lightning_invoice", "no-such-hash", reason="x") is None
