"""Linking a social handle straight to a TipMe account, and tipping it --
the ledger-transfer payment path that works today without the (not yet
built) external Lightning-send wallet."""
import pytest

from tipme_registry import page_metadata as page_metadata_module
from tipme_registry.storage import InsufficientBalance


def _signup(client, email, password="correct horse battery"):
    response = client.post("/v1/auth/signup", json={"email": email, "password": password})
    assert response.status_code == 201
    return response.json()["session_token"], response.json()["user_id"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _link(client, token, platform="instagram", username="friend"):
    return client.post("/v1/me/creators", headers=_auth(token),
                       json={"platform": platform, "username": username})


def _credit(user_id, asset, amount):
    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    storage.adjust_balance(user_id, asset, amount, reason="test_seed")


def _verify(client, platform="instagram", username="friend"):
    response = client.post(f"/v1/creators/{platform}/{username}/verify",
                           headers={"X-Admin-Token": "test-admin-token"})
    assert response.status_code == 200
    return response


# --------------------------------------------------------------------------
# Linking
# --------------------------------------------------------------------------

def test_link_creator_to_own_account(client):
    token, _ = _signup(client, "friend@example.com")
    response = _link(client, token)
    assert response.status_code == 201
    body = response.json()
    assert body["platform"] == "instagram"
    assert body["username"] == "friend"
    assert body["verified"] is False
    assert body["claim_token"]


def test_link_requires_a_session(client):
    response = client.post("/v1/me/creators", json={"platform": "instagram", "username": "friend"})
    assert response.status_code == 401


def test_auto_verify_links_dev_escape_hatch(client, monkeypatch):
    """REGISTRY_AUTO_VERIFY_LINKS=1 skips verification entirely so payments
    can be exercised without waiting on OAuth review or a real bio check --
    must default off, and a linked handle must actually be tippable once on."""
    from tipme_registry import app as app_module
    monkeypatch.setenv("REGISTRY_AUTO_VERIFY_LINKS", "1")
    app_module._settings = None

    sender_token, sender_id = _signup(client, "sender@example.com")
    receiver_token, _ = _signup(client, "receiver@example.com")
    link_response = _link(client, receiver_token)
    assert link_response.json()["verified"] is True
    _credit(sender_id, "bitcoin", 10_000)

    response = client.post("/v1/me/tip", headers=_auth(sender_token), json={
        "platform": "instagram", "username": "friend",
        "asset": "bitcoin", "amount_minor_units": 500,
    })
    assert response.status_code == 200


def test_linked_lookup_carries_tipme_user_id(client):
    token, user_id = _signup(client, "friend@example.com")
    _link(client, token)

    from tipme_registry import signing
    response = client.get("/v1/creators/instagram/friend")
    assert response.status_code == 200
    record = signing.verify_envelope(client.public_key, response.json())
    assert record["tipme_user_id"] == user_id
    assert record["lightning_address"] == ""


def test_relinking_the_same_handle_by_the_same_account_succeeds(client):
    token, _ = _signup(client, "friend@example.com")
    first = _link(client, token, username="oldhandle")
    assert first.status_code == 201
    second = _link(client, token, username="oldhandle", ) # same call, idempotent-ish
    assert second.status_code == 201


def test_an_unverified_claim_can_be_preempted_by_anyone(client):
    """An unverified claim is a provisional reservation, not a lock -- it
    proves nothing about who really controls the handle, so it must not be
    able to permanently freeze the real owner out of their own name."""
    token_a, user_a = _signup(client, "a@example.com")
    token_b, user_b = _signup(client, "b@example.com")
    _link(client, token_a, username="contested")

    response = _link(client, token_b, username="contested")
    assert response.status_code == 201

    from tipme_registry import signing
    lookup = client.get("/v1/creators/instagram/contested")
    record = signing.verify_envelope(client.public_key, lookup.json())
    assert record["tipme_user_id"] == user_b


def test_cannot_link_a_handle_someone_else_has_verified(client):
    token_a, _ = _signup(client, "a@example.com")
    token_b, _ = _signup(client, "b@example.com")
    _link(client, token_a, username="contested")
    _verify(client, username="contested")

    response = _link(client, token_b, username="contested")
    assert response.status_code == 403


def test_an_unverified_anonymous_claim_can_also_be_preempted(client):
    """Same rule from the other direction: an anonymous external-address
    claim (see `POST /v1/creators`) is exactly as unproven as a self-service
    TipMe link when nobody has verified it, so it gets the same treatment."""
    token, user_id = _signup(client, "friend@example.com")
    client.post("/v1/creators", json={
        "platform": "instagram", "username": "contested",
        "lightning_address": "someone@getalby.com",
    })

    response = _link(client, token, username="contested")
    assert response.status_code == 201

    from tipme_registry import signing
    lookup = client.get("/v1/creators/instagram/contested")
    record = signing.verify_envelope(client.public_key, lookup.json())
    assert record["tipme_user_id"] == user_id


def test_cannot_link_a_handle_already_anonymously_claimed_and_verified(client):
    token, _ = _signup(client, "friend@example.com")
    client.post("/v1/creators", json={
        "platform": "instagram", "username": "contested",
        "lightning_address": "someone@getalby.com",
    })
    _verify(client, username="contested")

    response = _link(client, token, username="contested")
    assert response.status_code == 403


def test_unlink_own_creator(client):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    response = client.delete("/v1/me/creators/instagram/friend", headers=_auth(token))
    assert response.status_code == 204
    assert client.get("/v1/creators/instagram/friend").status_code == 404


def test_cannot_unlink_someone_elses_linked_handle(client):
    token_a, _ = _signup(client, "a@example.com")
    token_b, _ = _signup(client, "b@example.com")
    _link(client, token_a, username="mine")

    response = client.delete("/v1/me/creators/instagram/mine", headers=_auth(token_b))
    assert response.status_code == 403
    assert client.get("/v1/creators/instagram/mine").status_code == 200


def test_generic_delete_endpoint_also_accepts_the_owning_session(client):
    """The pre-existing DELETE /v1/creators/... (management-token / admin
    path) should also work via a session that owns a TipMe-linked handle --
    one unlink surface, two ways to prove you're allowed to use it."""
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    response = client.delete("/v1/creators/instagram/friend", headers=_auth(token))
    assert response.status_code == 204


def test_request_verification_logs_for_the_owning_account(client, caplog):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    with caplog.at_level("WARNING"):
        response = client.post("/v1/me/creators/instagram/friend/request-verification",
                               headers=_auth(token))
    assert response.status_code == 200
    assert response.json()["status"] == "requested"
    assert "instagram:friend" in caplog.text
    assert "instagram.com/friend" in caplog.text


def test_request_verification_rejects_a_handle_you_do_not_own(client):
    token_a, _ = _signup(client, "a@example.com")
    token_b, _ = _signup(client, "b@example.com")
    _link(client, token_a, username="mine")

    response = client.post("/v1/me/creators/instagram/mine/request-verification",
                           headers=_auth(token_b))
    assert response.status_code == 403


def test_request_verification_is_a_no_op_once_already_verified(client):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)
    _verify(client)

    response = client.post("/v1/me/creators/instagram/friend/request-verification",
                           headers=_auth(token))
    assert response.status_code == 200
    assert response.json()["status"] == "already_verified"


# --------------------------------------------------------------------------
# Automated verification by fetching a claimed post's caption
# --------------------------------------------------------------------------

def _fake_fetch(og_description=None, meta_description=None, canonical_url=None, raises=None):
    async def fetch(url, *, timeout=6.0):
        if raises is not None:
            raise raises
        return page_metadata_module.PageMetadata(
            og_description=og_description, meta_description=meta_description, canonical_url=canonical_url)
    return fetch


def test_verify_by_link_succeeds_when_the_caption_carries_the_code(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    link_response = _link(client, token)
    claim_token = link_response.json()["claim_token"]

    monkeypatch.setattr(page_metadata_module, "fetch",
                        _fake_fetch(og_description=f"12 likes - friend on Sep 17: {claim_token} check me out"))

    response = client.post("/v1/me/creators/instagram/friend/verify-by-link",
                           headers=_auth(token), json={"post_url": "https://www.instagram.com/p/abc123/"})
    assert response.status_code == 200
    assert response.json()["status"] == "verified"

    from tipme_registry import signing
    lookup = client.get("/v1/creators/instagram/friend")
    record = signing.verify_envelope(client.public_key, lookup.json())
    assert record["verified"] is True


def test_verify_by_link_rejects_a_caption_without_the_code(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    monkeypatch.setattr(page_metadata_module, "fetch",
                        _fake_fetch(og_description="12 likes - friend on Sep 17: unrelated caption"))

    response = client.post("/v1/me/creators/instagram/friend/verify-by-link",
                           headers=_auth(token), json={"post_url": "https://www.instagram.com/p/abc123/"})
    assert response.status_code == 400

    from tipme_registry import signing
    lookup = client.get("/v1/creators/instagram/friend")
    record = signing.verify_envelope(client.public_key, lookup.json())
    assert record["verified"] is False


def test_verify_by_link_rejects_a_url_from_an_unsupported_domain(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    monkeypatch.setattr(page_metadata_module, "fetch",
                        _fake_fetch(og_description="doesn't matter, should never be called"))

    response = client.post("/v1/me/creators/instagram/friend/verify-by-link",
                           headers=_auth(token), json={"post_url": "https://evil.example/p/abc123/"})
    assert response.status_code == 400


def test_verify_by_link_surfaces_a_fetch_failure_clearly(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    monkeypatch.setattr(page_metadata_module, "fetch",
                        _fake_fetch(raises=page_metadata_module.PageFetchError("404")))

    response = client.post("/v1/me/creators/instagram/friend/verify-by-link",
                           headers=_auth(token), json={"post_url": "https://www.instagram.com/p/gone/"})
    assert response.status_code == 502


def test_verify_by_link_rejects_a_handle_you_do_not_own(client, monkeypatch):
    token_a, _ = _signup(client, "a@example.com")
    token_b, _ = _signup(client, "b@example.com")
    _link(client, token_a, username="mine")

    monkeypatch.setattr(page_metadata_module, "fetch", _fake_fetch(og_description="irrelevant"))

    response = client.post("/v1/me/creators/instagram/mine/verify-by-link",
                           headers=_auth(token_b), json={"post_url": "https://www.instagram.com/p/abc/"})
    assert response.status_code == 403


# --------------------------------------------------------------------------
# One-tap verification by fetching the creator's own profile bio
# --------------------------------------------------------------------------

def test_verify_by_bio_succeeds_when_the_bio_carries_the_code(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    link_response = _link(client, token)
    claim_token = link_response.json()["claim_token"]

    monkeypatch.setattr(page_metadata_module, "fetch",
                        _fake_fetch(meta_description=f'1 Follower - friend on Instagram: "{claim_token}"'))

    response = client.post("/v1/me/creators/instagram/friend/verify-by-bio", headers=_auth(token))
    assert response.status_code == 200
    assert response.json()["status"] == "verified"


def test_verify_by_bio_rejects_a_bio_without_the_code(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token)

    monkeypatch.setattr(page_metadata_module, "fetch",
                        _fake_fetch(meta_description='1 Follower - friend on Instagram: "just a normal bio"'))

    response = client.post("/v1/me/creators/instagram/friend/verify-by-bio", headers=_auth(token))
    assert response.status_code == 400


def test_verify_by_bio_refuses_tiktok(client, monkeypatch):
    token, _ = _signup(client, "friend@example.com")
    _link(client, token, platform="tiktok", username="friend")

    monkeypatch.setattr(page_metadata_module, "fetch", _fake_fetch(meta_description="should never be called"))

    response = client.post("/v1/me/creators/tiktok/friend/verify-by-bio", headers=_auth(token))
    assert response.status_code == 400
    assert "TikTok" in response.json()["detail"]


def test_verify_by_bio_rejects_a_handle_you_do_not_own(client, monkeypatch):
    token_a, _ = _signup(client, "a@example.com")
    token_b, _ = _signup(client, "b@example.com")
    _link(client, token_a, username="mine")

    monkeypatch.setattr(page_metadata_module, "fetch", _fake_fetch(meta_description="irrelevant"))

    response = client.post("/v1/me/creators/instagram/mine/verify-by-bio", headers=_auth(token_b))
    assert response.status_code == 403


# --------------------------------------------------------------------------
# Tipping (internal ledger transfer)
# --------------------------------------------------------------------------

def test_tip_a_linked_creator_moves_the_balance(client):
    sender_token, sender_id = _signup(client, "sender@example.com")
    _, receiver_id = _signup(client, "receiver@example.com")
    receiver_token2 = client.post("/v1/auth/login", json={
        "email": "receiver@example.com", "password": "correct horse battery",
    }).json()["session_token"]
    _link(client, receiver_token2)
    _verify(client)
    _credit(sender_id, "bitcoin", 10_000)

    response = client.post("/v1/me/tip", headers=_auth(sender_token), json={
        "platform": "instagram", "username": "friend",
        "asset": "bitcoin", "amount_minor_units": 3_000,
    })
    assert response.status_code == 200
    body = response.json()
    assert body["new_balance_minor_units"] == 7_000

    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    assert storage.get_balances(sender_id)["bitcoin"] == 7_000
    assert storage.get_balances(receiver_id)["bitcoin"] == 3_000


def test_tip_requires_a_session(client):
    response = client.post("/v1/me/tip", json={
        "platform": "instagram", "username": "friend",
        "asset": "bitcoin", "amount_minor_units": 100,
    })
    assert response.status_code == 401


def test_tip_rejects_insufficient_balance(client):
    sender_token, sender_id = _signup(client, "sender@example.com")
    receiver_token, _ = _signup(client, "receiver@example.com")
    _link(client, receiver_token)
    _verify(client)
    _credit(sender_id, "bitcoin", 100)

    response = client.post("/v1/me/tip", headers=_auth(sender_token), json={
        "platform": "instagram", "username": "friend",
        "asset": "bitcoin", "amount_minor_units": 500,
    })
    assert response.status_code == 402

    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    assert storage.get_balances(sender_id)["bitcoin"] == 100


def test_tip_rejects_a_handle_with_no_tipme_account(client):
    sender_token, sender_id = _signup(client, "sender@example.com")
    _credit(sender_id, "bitcoin", 10_000)
    client.post("/v1/creators", json={
        "platform": "tiktok", "username": "external",
        "lightning_address": "someone@getalby.com",
    })

    response = client.post("/v1/me/tip", headers=_auth(sender_token), json={
        "platform": "tiktok", "username": "external",
        "asset": "bitcoin", "amount_minor_units": 500,
    })
    assert response.status_code == 400


def test_tip_rejects_an_unverified_handle(client):
    sender_token, sender_id = _signup(client, "sender@example.com")
    receiver_token, _ = _signup(client, "receiver@example.com")
    _link(client, receiver_token)  # never verified
    _credit(sender_id, "bitcoin", 10_000)

    response = client.post("/v1/me/tip", headers=_auth(sender_token), json={
        "platform": "instagram", "username": "friend",
        "asset": "bitcoin", "amount_minor_units": 500,
    })
    assert response.status_code == 403

    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    assert storage.get_balances(sender_id)["bitcoin"] == 10_000


def test_tip_rejects_unregistered_handle(client):
    sender_token, sender_id = _signup(client, "sender@example.com")
    _credit(sender_id, "bitcoin", 10_000)

    response = client.post("/v1/me/tip", headers=_auth(sender_token), json={
        "platform": "tiktok", "username": "nobody",
        "asset": "bitcoin", "amount_minor_units": 500,
    })
    assert response.status_code == 404


def test_cannot_tip_your_own_linked_handle(client):
    token, user_id = _signup(client, "me@example.com")
    _link(client, token)
    _credit(user_id, "bitcoin", 10_000)

    response = client.post("/v1/me/tip", headers=_auth(token), json={
        "platform": "instagram", "username": "friend",
        "asset": "bitcoin", "amount_minor_units": 500,
    })
    assert response.status_code == 400


def test_transfer_balance_rejects_self_transfer_at_the_storage_layer():
    """Belt and suspenders under the API-level check above -- the storage
    primitive itself must never silently corrupt a same-account transfer."""
    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    with pytest.raises(ValueError):
        storage.transfer_balance("same-user", "same-user", "bitcoin", 100, reason="test")
