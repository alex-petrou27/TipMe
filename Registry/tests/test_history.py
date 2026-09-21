"""GET /v1/me/history: an account's own ledger, newest first."""
from tipme_registry import app as app_module


def _signup(client, email, password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def test_history_lists_only_the_callers_own_entries_newest_first(client):
    sender = _signup(client, "sender@example.com").json()
    recipient = _signup(client, "recipient@example.com").json()
    storage = app_module.get_storage(app_module.get_settings())
    storage.adjust_balance(sender["user_id"], "bitcoin", 5000, reason="lightning_deposit")
    client.post(
        "/v1/transfer",
        json={"to_email": "recipient@example.com", "asset": "bitcoin", "amount_minor": 2000},
        headers=_headers(sender["session_token"]),
    )

    mine = client.get("/v1/me/history", headers=_headers(sender["session_token"])).json()["entries"]
    assert [(e["reason"], e["delta_minor"]) for e in mine] == [
        ("internal_transfer_sent", -2000), ("lightning_deposit", 5000)]
    assert mine[0]["counterparty"] == "a TipMe user"
    assert mine[1]["counterparty"] is None

    theirs = client.get("/v1/me/history", headers=_headers(recipient["session_token"])).json()["entries"]
    assert [(e["reason"], e["delta_minor"]) for e in theirs] == [("internal_transfer_received", 2000)]


def test_history_requires_a_session(client):
    assert client.get("/v1/me/history").status_code == 401
