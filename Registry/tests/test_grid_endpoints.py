"""The Grid-specific HTTP endpoints: transfer, status check, and webhook.
All exercised against `FakeGridRail` -- never a real network call.
"""
from tipme_registry import grid_rail

from fakes import FakeGridRail


def _signup(client, email="alex@example.com", password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _authed_pair(client, monkeypatch):
    rail = FakeGridRail()
    monkeypatch.setattr(grid_rail, "rail_from_env", lambda: rail)
    sender = _signup(client, "sender@example.com").json()
    _signup(client, "recipient@example.com")
    return sender["session_token"], rail


# --- Transfer ---

def test_transfer_via_grid_provisions_both_customers_and_moves_money(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)

    response = client.post(
        "/v1/transfer/grid",
        json={"to_email": "recipient@example.com", "amount_minor": 500},
        headers=_headers(token),
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "COMPLETED"
    assert len(rail.funded) == 1
    assert rail.funded[0][1] == 500
    assert len(rail.transferred) == 1
    assert rail.transferred[0][2] == 500


def test_transfer_via_grid_reuses_the_same_customer_on_a_second_transfer(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)

    client.post(
        "/v1/transfer/grid", json={"to_email": "recipient@example.com", "amount_minor": 100},
        headers=_headers(token),
    )
    client.post(
        "/v1/transfer/grid", json={"to_email": "recipient@example.com", "amount_minor": 200},
        headers=_headers(token),
    )
    assert len(rail._customers) == 2


def test_transfer_via_grid_rejects_an_unknown_recipient(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    response = client.post(
        "/v1/transfer/grid",
        json={"to_email": "nobody@example.com", "amount_minor": 100},
        headers=_headers(token),
    )
    assert response.status_code == 404


def test_transfer_via_grid_rejects_transferring_to_yourself(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    response = client.post(
        "/v1/transfer/grid",
        json={"to_email": "sender@example.com", "amount_minor": 100},
        headers=_headers(token),
    )
    assert response.status_code == 400


def test_transfer_via_grid_fails_closed_when_not_configured(client, monkeypatch):
    monkeypatch.setattr(grid_rail, "rail_from_env", lambda: None)
    token = _signup(client, "sender@example.com").json()["session_token"]
    _signup(client, "recipient@example.com")
    response = client.post(
        "/v1/transfer/grid",
        json={"to_email": "recipient@example.com", "amount_minor": 100},
        headers=_headers(token),
    )
    assert response.status_code == 503


def test_transfer_via_grid_surfaces_rail_errors(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    rail.fail_next_transfer = True
    response = client.post(
        "/v1/transfer/grid",
        json={"to_email": "recipient@example.com", "amount_minor": 100},
        headers=_headers(token),
    )
    assert response.status_code == 502


# --- Status check ---

def test_check_grid_transfer_reports_the_current_status(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    created = client.post(
        "/v1/transfer/grid", json={"to_email": "recipient@example.com", "amount_minor": 100},
        headers=_headers(token),
    ).json()

    rail.set_transaction_status(created["grid_transaction_id"], "PENDING")
    response = client.post(
        f"/v1/transfer/grid/{created['grid_transaction_id']}/check", headers=_headers(token),
    )
    assert response.status_code == 200
    assert response.json()["status"] == "PENDING"


def test_check_grid_transfer_is_scoped_to_a_party_to_the_transfer(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    created = client.post(
        "/v1/transfer/grid", json={"to_email": "recipient@example.com", "amount_minor": 100},
        headers=_headers(token),
    ).json()

    other_token = _signup(client, "someone_else@example.com").json()["session_token"]
    response = client.post(
        f"/v1/transfer/grid/{created['grid_transaction_id']}/check", headers=_headers(other_token),
    )
    assert response.status_code == 404


def test_check_grid_transfer_rejects_an_unknown_transaction(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    response = client.post(
        "/v1/transfer/grid/Transaction:unknown/check", headers=_headers(token),
    )
    assert response.status_code == 404


# --- Webhook ---

def test_webhook_updates_the_matching_transfer_status(client, monkeypatch):
    token, rail = _authed_pair(client, monkeypatch)
    created = client.post(
        "/v1/transfer/grid", json={"to_email": "recipient@example.com", "amount_minor": 100},
        headers=_headers(token),
    ).json()

    rail.queue_webhook_event(created["grid_transaction_id"], "COMPLETED")
    response = client.post(
        "/v1/webhooks/grid", content=b"{}",
        headers={"X-Grid-Signature": "valid-signature"},
    )
    assert response.status_code == 204

    check = client.post(
        f"/v1/transfer/grid/{created['grid_transaction_id']}/check", headers=_headers(token),
    ).json()
    assert check["status"] == "COMPLETED"


def test_webhook_rejects_a_bad_signature(client, monkeypatch):
    _token, rail = _authed_pair(client, monkeypatch)
    rail.queue_webhook_event("Transaction:1", "COMPLETED")

    response = client.post(
        "/v1/webhooks/grid", content=b"{}",
        headers={"X-Grid-Signature": "wrong-signature"},
    )
    assert response.status_code == 401


def test_webhook_fails_closed_when_grid_is_not_configured(client, monkeypatch):
    monkeypatch.setattr(grid_rail, "rail_from_env", lambda: None)
    response = client.post(
        "/v1/webhooks/grid", content=b"{}",
        headers={"X-Grid-Signature": "valid-signature"},
    )
    assert response.status_code == 503


def test_webhook_is_a_harmless_no_op_for_an_unknown_transaction(client, monkeypatch):
    _token, rail = _authed_pair(client, monkeypatch)
    rail.queue_webhook_event("Transaction:unknown", "COMPLETED")

    response = client.post(
        "/v1/webhooks/grid", content=b"{}",
        headers={"X-Grid-Signature": "valid-signature"},
    )
    assert response.status_code == 204
