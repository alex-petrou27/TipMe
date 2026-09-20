"""Tipping a creator directly out of the sender's ledger balance, when the
creator's handle is linked to a TipMe account -- the core "person on my
screen -> pay them" loop, with no Lightning/Grid/external rail involved.
"""
from tipme_registry import signing


def _signup(client, email, password="correct horse battery"):
    return client.post("/v1/auth/signup", json={"email": email, "password": password})


def _headers(token):
    return {"Authorization": f"Bearer {token}"}


def _register(client, platform, username, token=None, lightning_address="someone@getalby.com"):
    headers = _headers(token) if token else {}
    return client.post(
        "/v1/creators",
        json={"platform": platform, "username": username, "lightning_address": lightning_address},
        headers=headers,
    )


def _decode(client, response):
    return signing.verify_envelope(client.public_key, response.json())


def test_registering_while_signed_in_links_the_handle(client):
    creator = _signup(client, "creator@example.com").json()
    _register(client, "tiktok", "creator", token=creator["session_token"])

    lookup = client.get("/v1/creators/tiktok/creator")
    record = _decode(client, lookup)
    assert record["tipme_linked"] is True


def test_registering_signed_out_does_not_link_the_handle(client):
    _register(client, "tiktok", "creator")

    lookup = client.get("/v1/creators/tiktok/creator")
    record = _decode(client, lookup)
    assert record["tipme_linked"] is False


def test_tip_moves_balance_from_sender_to_linked_creator(client):
    creator = _signup(client, "creator@example.com").json()
    sender = _signup(client, "sender@example.com").json()
    _register(client, "tiktok", "creator", token=creator["session_token"])

    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    storage.adjust_balance(sender["user_id"], "bitcoin", 5000, reason="test_seed")

    response = client.post(
        "/v1/tip/tiktok/creator",
        json={"asset": "bitcoin", "amount_minor": 2000},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 200
    assert {b["asset"]: b["balance_minor"] for b in response.json()["balances"]}["bitcoin"] == 3000

    creator_me = client.get("/v1/me", headers=_headers(creator["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in creator_me["balances"]}["bitcoin"] == 2000


def test_tip_rejects_a_creator_with_no_linked_account(client):
    sender = _signup(client, "sender@example.com").json()
    _register(client, "tiktok", "creator")  # signed out -- no link

    response = client.post(
        "/v1/tip/tiktok/creator",
        json={"asset": "bitcoin", "amount_minor": 100},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 404


def test_tip_rejects_an_unregistered_handle(client):
    sender = _signup(client, "sender@example.com").json()
    response = client.post(
        "/v1/tip/tiktok/nobody",
        json={"asset": "bitcoin", "amount_minor": 100},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 404


def test_tip_rejects_insufficient_balance_without_touching_either_side(client):
    creator = _signup(client, "creator@example.com").json()
    sender = _signup(client, "sender@example.com").json()
    _register(client, "tiktok", "creator", token=creator["session_token"])

    response = client.post(
        "/v1/tip/tiktok/creator",
        json={"asset": "bitcoin", "amount_minor": 2000},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 402

    creator_me = client.get("/v1/me", headers=_headers(creator["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in creator_me["balances"]}["bitcoin"] == 0


def test_tip_rejects_tipping_yourself(client):
    creator = _signup(client, "creator@example.com").json()
    _register(client, "tiktok", "creator", token=creator["session_token"])

    response = client.post(
        "/v1/tip/tiktok/creator",
        json={"asset": "bitcoin", "amount_minor": 100},
        headers=_headers(creator["session_token"]),
    )
    assert response.status_code == 400


def test_tip_requires_authentication(client):
    response = client.post(
        "/v1/tip/tiktok/creator",
        json={"asset": "bitcoin", "amount_minor": 100},
    )
    assert response.status_code == 401


def test_tip_rejects_an_unknown_asset(client):
    creator = _signup(client, "creator@example.com").json()
    sender = _signup(client, "sender@example.com").json()
    _register(client, "tiktok", "creator", token=creator["session_token"])

    response = client.post(
        "/v1/tip/tiktok/creator",
        json={"asset": "dogecoin", "amount_minor": 100},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 400
