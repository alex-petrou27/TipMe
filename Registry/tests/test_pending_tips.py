"""Tips sent to a handle nobody has claimed on TipMe yet.

The core scenario: someone shares a friend's Instagram post and tips them
before that friend has ever heard of TipMe. The money is debited from the
sender immediately and held in escrow against the exact (platform,
username), released only once real proof -- OAuth or an admin's manual
check -- shows who actually controls that handle.

The security-critical half of this file is the squatter tests: a pending
tip must never be releasable just because *someone* registered the right
username string and pointed it at their own account. Plain registration and
self-verify must never unlock escrowed money, only "oauth"/"admin".
"""
from tipme_registry import oauth as oauth_module


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


def _seed(client, user_id, asset="bitcoin", amount=5000):
    from tipme_registry import app as app_module
    storage = app_module.get_storage(app_module.get_settings())
    storage.adjust_balance(user_id, asset, amount, reason="test_seed")


def _fake_config():
    return oauth_module.PlatformOAuthConfig(
        platform="instagram",
        client_id="test-client-id",
        client_secret="test-secret",
        redirect_uri="https://registry.example/v1/oauth/instagram/callback",
        authorize_base="https://www.instagram.com/oauth/authorize",
        scope="instagram_business_basic",
    )


def _oauth_start(client, monkeypatch, username, token=None):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.post(
        "/v1/oauth/instagram/start",
        json={"platform": "instagram", "username": username, "lightning_address": "x@getalby.com"},
        headers=_headers(token) if token else {},
    )
    assert response.status_code == 200
    url = response.json()["authorize_url"]
    return dict(part.split("=", 1) for part in url.split("?", 1)[1].split("&"))["state"]


def _oauth_finish(client, monkeypatch, state, username):
    async def fake_exchange(config, code):
        return username, "platform-user-id-1"

    monkeypatch.setattr(oauth_module, "exchange_code", fake_exchange)
    response = client.get(
        "/v1/oauth/instagram/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )
    location = response.headers["location"]
    query = location.split("?", 1)[1]
    params = dict((k, v) for k, v in (p.split("=", 1) for p in query.split("&")))
    assert params["status"] == "success"
    return client.get(f"/v1/oauth/session/{params['session_id']}").json()


# ---------------------------------------------------------------------
# Sending: escrow only applies to a truly-unclaimed handle
# ---------------------------------------------------------------------

def test_tip_pending_debits_sender_and_creates_escrow(client):
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])

    response = client.post(
        "/v1/tip/instagram/futurecreator/pending",
        json={"asset": "bitcoin", "amount_minor": 500, "note": "a pint on me"},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 201
    body = response.json()
    assert body["pending_tip_id"]
    assert {b["asset"]: b["balance_minor"] for b in body["balances"]}["bitcoin"] == 4500

    listing = client.get("/v1/tip/pending", headers=_headers(sender["session_token"])).json()
    assert len(listing["tips"]) == 1
    assert listing["tips"][0]["status"] == "pending"
    assert listing["tips"][0]["note"] == "a pint on me"


def test_tip_pending_rejects_insufficient_balance(client):
    sender = _signup(client, "sender@example.com").json()
    response = client.post(
        "/v1/tip/instagram/futurecreator/pending",
        json={"asset": "bitcoin", "amount_minor": 500},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 402

    listing = client.get("/v1/tip/pending", headers=_headers(sender["session_token"])).json()
    assert listing["tips"] == []


def test_tip_pending_refuses_an_already_registered_handle(client):
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    _register(client, "instagram", "already_here")  # external wallet, unlinked

    response = client.post(
        "/v1/tip/instagram/already_here/pending",
        json={"asset": "bitcoin", "amount_minor": 500},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 409


def test_tip_pending_requires_authentication(client):
    response = client.post(
        "/v1/tip/instagram/futurecreator/pending",
        json={"asset": "bitcoin", "amount_minor": 500},
    )
    assert response.status_code == 401


# ---------------------------------------------------------------------
# Reclaiming: the sender's own "take back"
# ---------------------------------------------------------------------

def test_sender_can_reclaim_an_unclaimed_pending_tip(client):
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    created = client.post(
        "/v1/tip/instagram/futurecreator/pending",
        json={"asset": "bitcoin", "amount_minor": 500},
        headers=_headers(sender["session_token"]),
    ).json()

    response = client.post(
        f"/v1/tip/pending/{created['pending_tip_id']}/reclaim",
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 200
    assert {b["asset"]: b["balance_minor"] for b in response.json()["balances"]}["bitcoin"] == 5000

    listing = client.get("/v1/tip/pending", headers=_headers(sender["session_token"])).json()
    assert listing["tips"][0]["status"] == "reclaimed"


def test_reclaim_rejects_a_different_users_pending_tip(client):
    sender = _signup(client, "sender@example.com").json()
    stranger = _signup(client, "stranger@example.com").json()
    _seed(client, sender["user_id"])
    created = client.post(
        "/v1/tip/instagram/futurecreator/pending",
        json={"asset": "bitcoin", "amount_minor": 500},
        headers=_headers(sender["session_token"]),
    ).json()

    response = client.post(
        f"/v1/tip/pending/{created['pending_tip_id']}/reclaim",
        headers=_headers(stranger["session_token"]),
    )
    assert response.status_code == 404


def test_cannot_reclaim_twice(client):
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    created = client.post(
        "/v1/tip/instagram/futurecreator/pending",
        json={"asset": "bitcoin", "amount_minor": 500},
        headers=_headers(sender["session_token"]),
    ).json()
    client.post(f"/v1/tip/pending/{created['pending_tip_id']}/reclaim",
                headers=_headers(sender["session_token"]))

    second = client.post(
        f"/v1/tip/pending/{created['pending_tip_id']}/reclaim",
        headers=_headers(sender["session_token"]),
    )
    assert second.status_code == 404


# ---------------------------------------------------------------------
# Claiming: only real proof releases escrow
# ---------------------------------------------------------------------

def test_plain_registration_does_not_release_pending_tips(client):
    """The core theft scenario this whole mechanism has to resist: someone
    signs up and registers a famous handle, pointing it at their own
    account. That alone must never pay out anything sitting in escrow."""
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    client.post(
        "/v1/tip/instagram/famous/pending",
        json={"asset": "bitcoin", "amount_minor": 1500},
        headers=_headers(sender["session_token"]),
    )

    squatter = _signup(client, "squatter@example.com").json()
    register = _register(client, "instagram", "famous", token=squatter["session_token"])
    assert register.status_code == 201

    squatter_me = client.get("/v1/me", headers=_headers(squatter["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in squatter_me["balances"]}.get("bitcoin", 0) == 0


def test_self_verify_does_not_release_pending_tips(client):
    """Self-verify proves only "I know this record's claim token", not
    platform identity -- see its own docstring. It must not be usable to
    drain an escrow either."""
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    client.post(
        "/v1/tip/instagram/famous/pending",
        json={"asset": "bitcoin", "amount_minor": 1500},
        headers=_headers(sender["session_token"]),
    )

    squatter = _signup(client, "squatter@example.com").json()
    register = _register(client, "instagram", "famous", token=squatter["session_token"]).json()

    self_verify = client.post(
        "/v1/creators/instagram/famous/self-verify",
        json={"claim_token": register["claim_token"]},
        headers=_headers(squatter["session_token"]),
    )
    assert self_verify.status_code == 200
    assert self_verify.json()["verified_via"] == "self"

    squatter_me = client.get("/v1/me", headers=_headers(squatter["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in squatter_me["balances"]}.get("bitcoin", 0) == 0


def test_admin_verification_releases_pending_tips(client):
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    client.post(
        "/v1/tip/instagram/famous/pending",
        json={"asset": "bitcoin", "amount_minor": 1500, "note": "congrats!"},
        headers=_headers(sender["session_token"]),
    )

    creator = _signup(client, "creator@example.com").json()
    _register(client, "instagram", "famous", token=creator["session_token"])

    verify = client.post(
        "/v1/creators/instagram/famous/verify",
        headers={"x-admin-token": "test-admin-token"},
    )
    assert verify.status_code == 200

    creator_me = client.get("/v1/me", headers=_headers(creator["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in creator_me["balances"]}["bitcoin"] == 1500

    listing = client.get("/v1/tip/pending", headers=_headers(sender["session_token"])).json()
    assert listing["tips"][0]["status"] == "claimed"


def test_oauth_link_releases_pending_tips_for_the_linking_account(client, monkeypatch):
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    client.post(
        "/v1/tip/instagram/famous/pending",
        json={"asset": "bitcoin", "amount_minor": 1500},
        headers=_headers(sender["session_token"]),
    )

    real_owner = _signup(client, "real@example.com").json()
    state = _oauth_start(client, monkeypatch, "famous", token=real_owner["session_token"])
    session = _oauth_finish(client, monkeypatch, state, "famous")

    assert len(session["claimed"]) == 1
    assert session["claimed"][0]["amount_minor"] == 1500

    owner_me = client.get("/v1/me", headers=_headers(real_owner["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in owner_me["balances"]}["bitcoin"] == 1500


def test_anonymous_oauth_link_does_not_credit_a_stale_squatter(client, monkeypatch):
    """The subtler version of the squatter attack: a squatter registers
    `famous` while signed in, pointing it at their own account, then the
    real owner comes along and OAuth-verifies *without* being signed in to
    TipMe (proving the handle is theirs, but not linking any TipMe account
    of their own). `tipme_user_id` on the record still COALESCEs back to
    the squatter -- so releasing pending tips off of that column, instead
    of off of who this exact OAuth exchange just verified, would still hand
    the squatter the money on the back of someone else's identity check.
    """
    sender = _signup(client, "sender@example.com").json()
    _seed(client, sender["user_id"])
    client.post(
        "/v1/tip/instagram/famous/pending",
        json={"asset": "bitcoin", "amount_minor": 1500},
        headers=_headers(sender["session_token"]),
    )

    squatter = _signup(client, "squatter@example.com").json()
    _register(client, "instagram", "famous", token=squatter["session_token"])

    state = _oauth_start(client, monkeypatch, "famous", token=None)  # anonymous
    session = _oauth_finish(client, monkeypatch, state, "famous")
    assert session["verified"] is True
    assert session["claimed"] == []  # nobody proven-and-linked together -- nothing released

    squatter_me = client.get("/v1/me", headers=_headers(squatter["session_token"])).json()
    assert {b["asset"]: b["balance_minor"] for b in squatter_me["balances"]}.get("bitcoin", 0) == 0

    listing = client.get("/v1/tip/pending", headers=_headers(sender["session_token"])).json()
    assert listing["tips"][0]["status"] == "pending"
