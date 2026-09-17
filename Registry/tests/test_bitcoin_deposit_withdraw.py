"""On-chain Bitcoin deposit/withdraw against the custodial ledger.

Never talks to a real chain or explorer -- `bitcoin_chain.rail_from_env` is
monkeypatched to return `FakeOnChainRail`, the same convention
`test_deposit_withdraw.py` uses for the Lightning rail.
"""
from tipme_registry import bitcoin_chain

from fakes import FakeOnChainRail


def _signup(client, email="alex@example.com", password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _authed(client, monkeypatch):
    rail = FakeOnChainRail()
    monkeypatch.setattr(bitcoin_chain, "rail_from_env", lambda: rail)
    token = _signup(client).json()["session_token"]
    return token, rail


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _deposit_and_confirm(client, token, rail, amount_sats=50000):
    address = client.post("/v1/deposit/bitcoin", headers=_headers(token)).json()["address"]
    rail.receive(address, amount_sats)
    client.post(f"/v1/deposit/bitcoin/{address}/check", headers=_headers(token))
    return address


# --- Configuration ---

def test_deposit_fails_closed_when_not_configured(client, monkeypatch):
    monkeypatch.setattr(bitcoin_chain, "rail_from_env", lambda: None)
    token = _signup(client).json()["session_token"]
    response = client.post("/v1/deposit/bitcoin", headers=_headers(token))
    assert response.status_code == 503


def test_withdraw_fails_closed_when_not_configured(client, monkeypatch):
    monkeypatch.setattr(bitcoin_chain, "rail_from_env", lambda: None)
    token = _signup(client).json()["session_token"]
    response = client.post(
        "/v1/withdraw/bitcoin", json={"to_address": "bc1qmock", "amount_sats": 5000},
        headers=_headers(token),
    )
    assert response.status_code == 503


# --- Deposits ---

def test_deposit_issues_an_address_without_crediting_anything(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    response = client.post("/v1/deposit/bitcoin", headers=_headers(token))
    assert response.status_code == 200
    assert response.json()["address"]

    me = client.get("/v1/me", headers=_headers(token)).json()
    assert {b["asset"]: b["balance_minor"] for b in me["balances"]} == {"bitcoin": 0, "usdt": 0}


def test_two_deposit_requests_get_different_addresses(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    first = client.post("/v1/deposit/bitcoin", headers=_headers(token)).json()["address"]
    second = client.post("/v1/deposit/bitcoin", headers=_headers(token)).json()["address"]
    assert first != second


def test_checking_an_unpaid_address_reports_pending_and_credits_nothing(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    address = client.post("/v1/deposit/bitcoin", headers=_headers(token)).json()["address"]

    response = client.post(f"/v1/deposit/bitcoin/{address}/check", headers=_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "pending"
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 0


def test_checking_a_paid_address_credits_the_ledger_with_the_observed_amount(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    address = client.post("/v1/deposit/bitcoin", headers=_headers(token)).json()["address"]

    rail.receive(address, 42000)
    first = client.post(f"/v1/deposit/bitcoin/{address}/check", headers=_headers(token))
    assert first.status_code == 200
    body = first.json()
    assert body["status"] == "completed"
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 42000

    # A repeated check must not credit the ledger a second time, even if
    # more funds subsequently arrive at the same address.
    rail.receive(address, 1000)
    second = client.post(f"/v1/deposit/bitcoin/{address}/check", headers=_headers(token))
    assert {b["asset"]: b["balance_minor"] for b in second.json()["balances"]}["bitcoin"] == 42000


def test_deposit_check_is_scoped_to_the_owning_user(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    address = client.post("/v1/deposit/bitcoin", headers=_headers(token)).json()["address"]

    other_token = _signup(client, email="other@example.com").json()["session_token"]
    response = client.post(f"/v1/deposit/bitcoin/{address}/check", headers=_headers(other_token))
    assert response.status_code == 404


def test_checking_an_unknown_address_is_a_404(client, monkeypatch):
    token, _rail = _authed(client, monkeypatch)
    response = client.post("/v1/deposit/bitcoin/not-a-real-address/check", headers=_headers(token))
    assert response.status_code == 404


# --- Withdrawals ---

def test_withdrawal_sends_and_debits_the_balance(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_confirm(client, token, rail, amount_sats=50000)

    response = client.post(
        "/v1/withdraw/bitcoin", json={"to_address": "bc1qexternal", "amount_sats": 20000},
        headers=_headers(token),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["amount_sats"] == 20000
    assert body["txid"]
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 30000
    assert ("bc1qexternal", 20000) in rail.sent


def test_withdrawal_refunds_the_balance_when_the_send_fails(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_confirm(client, token, rail, amount_sats=50000)

    rail.fail_next_send = True
    response = client.post(
        "/v1/withdraw/bitcoin", json={"to_address": "bc1qexternal", "amount_sats": 20000},
        headers=_headers(token),
    )
    assert response.status_code == 502

    me = client.get("/v1/me", headers=_headers(token)).json()
    assert {b["asset"]: b["balance_minor"] for b in me["balances"]}["bitcoin"] == 50000


def test_withdrawal_rejects_insufficient_balance_without_attempting_a_send(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)

    response = client.post(
        "/v1/withdraw/bitcoin", json={"to_address": "bc1qexternal", "amount_sats": 20000},
        headers=_headers(token),
    )
    assert response.status_code == 402
    assert rail.sent == []


def test_withdrawal_rejects_amounts_below_the_dust_floor(client, monkeypatch):
    token, rail = _authed(client, monkeypatch)
    _deposit_and_confirm(client, token, rail, amount_sats=50000)

    response = client.post(
        "/v1/withdraw/bitcoin", json={"to_address": "bc1qexternal", "amount_sats": 1},
        headers=_headers(token),
    )
    assert response.status_code == 422
