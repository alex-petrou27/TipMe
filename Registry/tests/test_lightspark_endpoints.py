"""The two Lightspark-specific HTTP endpoints: the sandbox test-payment
simulator and the webhook. Both are exercised against `FakeLightsparkRail`
-- never a real network call or the real SDK.
"""
from lightspark import WebhookEventType

from tipme_registry import lightning_node, lightspark_rail

from fakes import FakeLightningRail, FakeLightsparkRail


def _signup(client, email="alex@example.com", password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _authed_with_lightspark(client, monkeypatch):
    rail = FakeLightsparkRail()
    monkeypatch.setattr(lightspark_rail, "rail_from_env", lambda: rail)
    token = _signup(client).json()["session_token"]
    return token, rail


# --- Simulate test payment ---

def test_simulate_test_payment_settles_the_invoice(client, monkeypatch):
    token, rail = _authed_with_lightspark(client, monkeypatch)
    created = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token)).json()

    response = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/simulate-test-payment",
        json={"payment_request": created["payment_request"]},
        headers=_headers(token),
    )
    assert response.status_code == 204

    check = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/check", headers=_headers(token),
    ).json()
    assert check["status"] == "completed"
    assert {b["asset"]: b["balance_minor"] for b in check["balances"]}["bitcoin"] == 1000


def test_simulate_test_payment_rejects_a_rail_that_does_not_support_it(client, monkeypatch):
    monkeypatch.setattr(lightspark_rail, "rail_from_env", lambda: None)
    plain_rail = FakeLightningRail()
    monkeypatch.setattr(lightning_node, "rail_from_env", lambda: plain_rail)
    token = _signup(client).json()["session_token"]
    created = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token)).json()

    response = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/simulate-test-payment",
        json={"payment_request": created["payment_request"]},
        headers=_headers(token),
    )
    assert response.status_code == 400


def test_simulate_test_payment_is_scoped_to_the_owning_user(client, monkeypatch):
    token, rail = _authed_with_lightspark(client, monkeypatch)
    created = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token)).json()

    other_token = _signup(client, email="other@example.com").json()["session_token"]
    response = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/simulate-test-payment",
        json={"payment_request": created["payment_request"]},
        headers=_headers(other_token),
    )
    assert response.status_code == 404


def test_simulate_test_payment_surfaces_rail_errors(client, monkeypatch):
    token, rail = _authed_with_lightspark(client, monkeypatch)
    created = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token)).json()

    rail.fail_next_simulate = True
    response = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/simulate-test-payment",
        json={"payment_request": created["payment_request"]},
        headers=_headers(token),
    )
    assert response.status_code == 502


# --- Webhook ---

def test_webhook_completes_the_matching_pending_deposit(client, monkeypatch):
    token, rail = _authed_with_lightspark(client, monkeypatch)
    created = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token)).json()

    rail.register_incoming_payment("incoming-1", transaction_hash=created["payment_hash"])
    rail.queue_webhook_event(WebhookEventType.FUNDS_RECEIVED, "incoming-1")

    response = client.post(
        "/v1/webhooks/lightspark", content=b"{}",
        headers={"lightspark-signature": "valid-signature"},
    )
    assert response.status_code == 204

    check = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/check", headers=_headers(token),
    ).json()
    assert check["status"] == "completed"


def test_webhook_ignores_event_types_other_than_funds_received(client, monkeypatch):
    token, rail = _authed_with_lightspark(client, monkeypatch)
    created = client.post("/v1/deposit/lightning", json={"amount_sats": 1000}, headers=_headers(token)).json()

    rail.register_incoming_payment("incoming-1", transaction_hash=created["payment_hash"])
    rail.queue_webhook_event(WebhookEventType.PAYMENT_FINISHED, "incoming-1")

    response = client.post(
        "/v1/webhooks/lightspark", content=b"{}",
        headers={"lightspark-signature": "valid-signature"},
    )
    assert response.status_code == 204

    check = client.post(
        f"/v1/deposit/lightning/{created['payment_hash']}/check", headers=_headers(token),
    ).json()
    assert check["status"] == "pending"


def test_webhook_rejects_a_bad_signature(client, monkeypatch):
    _token, rail = _authed_with_lightspark(client, monkeypatch)
    rail.queue_webhook_event(WebhookEventType.FUNDS_RECEIVED, "incoming-1")

    response = client.post(
        "/v1/webhooks/lightspark", content=b"{}",
        headers={"lightspark-signature": "wrong-signature"},
    )
    assert response.status_code == 401


def test_webhook_fails_closed_when_lightspark_is_not_configured(client, monkeypatch):
    monkeypatch.setattr(lightspark_rail, "rail_from_env", lambda: None)
    response = client.post(
        "/v1/webhooks/lightspark", content=b"{}",
        headers={"lightspark-signature": "valid-signature"},
    )
    assert response.status_code == 503


def test_webhook_is_a_harmless_no_op_for_an_unknown_payment(client, monkeypatch):
    _token, rail = _authed_with_lightspark(client, monkeypatch)
    # No incoming payment registered for this id at all.
    rail.queue_webhook_event(WebhookEventType.FUNDS_RECEIVED, "unknown-payment")

    response = client.post(
        "/v1/webhooks/lightspark", content=b"{}",
        headers={"lightspark-signature": "valid-signature"},
    )
    assert response.status_code == 204
