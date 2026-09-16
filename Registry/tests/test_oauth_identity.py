"""Identity-only sign-in: proves a sender controls @handle without writing
anything to the creator directory. Same monkeypatched exchange_code as
test_oauth.py — no real network calls."""
from tipme_registry import oauth as oauth_module


def _fake_config():
    return oauth_module.PlatformOAuthConfig(
        platform="tiktok",
        client_id="test-client-id",
        client_secret="test-secret",
        redirect_uri="https://registry.example/v1/oauth/tiktok/identity/callback",
        authorize_base="https://www.tiktok.com/v2/auth/authorize/",
        scope="user.info.basic",
    )


def _redirect_params(response):
    location = response.headers["location"]
    query = location.split("?", 1)[1]
    return dict(
        (key, value.replace("+", " "))
        for key, value in (part.split("=", 1) for part in query.split("&"))
    )


def test_identity_start_without_configured_platform_fails_closed(client):
    assert client.post("/v1/oauth/tiktok/identity/start").status_code == 503


def test_identity_start_returns_authorize_url(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.post("/v1/oauth/tiktok/identity/start")
    assert response.status_code == 200
    assert response.json()["authorize_url"].startswith("https://www.tiktok.com/v2/auth/authorize/?")


def test_identity_flow_never_touches_the_creator_directory(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    start = client.post("/v1/oauth/tiktok/identity/start")
    url = start.json()["authorize_url"]
    state = dict(part.split("=", 1) for part in url.split("?", 1)[1].split("&"))["state"]

    async def fake_exchange(config, code):
        return "sender_handle", "999"

    monkeypatch.setattr(oauth_module, "exchange_code", fake_exchange)

    callback = client.get(
        "/v1/oauth/tiktok/identity/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )
    params = _redirect_params(callback)
    assert params["status"] == "success"
    assert params["username"] == "sender_handle"

    session = client.get(f"/v1/oauth/identity-session/{params['session_id']}")
    assert session.status_code == 200
    assert session.json() == {"platform": "tiktok", "username": "sender_handle"}

    # Burned after one read, and — the whole point — nothing was written.
    assert client.get(f"/v1/oauth/identity-session/{params['session_id']}").status_code == 404
    assert client.get("/v1/creators/tiktok/sender_handle").status_code == 404


def test_identity_callback_rejects_unknown_state(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.get(
        "/v1/oauth/tiktok/identity/callback",
        params={"code": "auth-code", "state": "not-a-real-state"},
        follow_redirects=False,
    )
    params = _redirect_params(response)
    assert params["status"] == "error"
    assert params["reason"] == "expired_or_invalid_state"


def test_identity_callback_passes_through_platform_denial(client):
    response = client.get(
        "/v1/oauth/tiktok/identity/callback",
        params={"error": "access_denied"},
        follow_redirects=False,
    )
    params = _redirect_params(response)
    assert params["status"] == "error"
    assert params["reason"] == "access_denied"
