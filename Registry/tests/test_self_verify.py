"""Self-service verification for a handle linked to a signed-in TipMe account.

Exists because Meta's April 2025 changes left personal Instagram accounts with
no API path at all -- not OAuth, not oEmbed, nothing -- so a "verified" badge
gated behind platform sign-in is a badge most real users can never earn. See
`self_verify`'s own docstring in app.py for why marking a handle verified this
way is still safe: `verified` was never what stops a tip reaching the wrong
wallet.
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


def test_self_verify_marks_the_handle_verified(client):
    creator = _signup(client, "creator@example.com").json()
    registration = _register(client, "tiktok", "creator", token=creator["session_token"]).json()

    response = client.post(
        "/v1/creators/tiktok/creator/self-verify",
        json={"claim_token": registration["claim_token"]},
        headers=_headers(creator["session_token"]),
    )
    assert response.status_code == 200
    assert response.json()["verified_via"] == "self"

    record = _decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["verified"] is True
    assert record["verified_via"] == "self"


def test_self_verify_requires_authentication(client, registered):
    response = client.post(
        "/v1/creators/tiktok/creator/self-verify",
        json={"claim_token": registered["claim_token"]},
    )
    assert response.status_code == 401


def test_self_verify_rejects_an_unlinked_handle(client):
    sender = _signup(client, "sender@example.com").json()
    registration = _register(client, "tiktok", "creator").json()  # signed out -- no link

    response = client.post(
        "/v1/creators/tiktok/creator/self-verify",
        json={"claim_token": registration["claim_token"]},
        headers=_headers(sender["session_token"]),
    )
    assert response.status_code == 403


def test_self_verify_rejects_someone_elses_linked_handle(client):
    creator = _signup(client, "creator@example.com").json()
    impostor = _signup(client, "impostor@example.com").json()
    registration = _register(client, "tiktok", "creator", token=creator["session_token"]).json()

    response = client.post(
        "/v1/creators/tiktok/creator/self-verify",
        json={"claim_token": registration["claim_token"]},
        headers=_headers(impostor["session_token"]),
    )
    assert response.status_code == 403

    record = _decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["verified"] is False


def test_self_verify_rejects_the_wrong_claim_token(client):
    creator = _signup(client, "creator@example.com").json()
    _register(client, "tiktok", "creator", token=creator["session_token"])

    response = client.post(
        "/v1/creators/tiktok/creator/self-verify",
        json={"claim_token": "not-the-real-token"},
        headers=_headers(creator["session_token"]),
    )
    assert response.status_code == 400

    record = _decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["verified"] is False


def test_self_verify_rejects_an_unregistered_handle(client):
    creator = _signup(client, "creator@example.com").json()

    response = client.post(
        "/v1/creators/tiktok/nobody/self-verify",
        json={"claim_token": "anything"},
        headers=_headers(creator["session_token"]),
    )
    assert response.status_code == 404


def test_re_registering_clears_a_self_verified_badge_same_as_any_other(client):
    """Changing the wallet a handle points at invalidates any earlier
    verification, self-verify included -- same rule `upsert` already applies
    to the oauth/admin tiers."""
    creator = _signup(client, "creator@example.com").json()
    registration = _register(client, "tiktok", "creator", token=creator["session_token"]).json()
    client.post(
        "/v1/creators/tiktok/creator/self-verify",
        json={"claim_token": registration["claim_token"]},
        headers=_headers(creator["session_token"]),
    )

    client.post(
        "/v1/creators",
        json={"platform": "tiktok", "username": "creator",
              "lightning_address": "somewhere-else@getalby.com"},
        headers={**_headers(creator["session_token"]),
                 "X-Management-Token": registration["management_token"]},
    )

    record = _decode(client, client.get("/v1/creators/tiktok/creator"))
    assert record["verified"] is False
    assert record["verified_via"] is None
