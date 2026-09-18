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
    monkeypatch.setattr(oauth_module, "config_for", lambda platform, purpose="claim": _fake_config())
    response = client.post("/v1/oauth/tiktok/identity/start")
    assert response.status_code == 200
    assert response.json()["authorize_url"].startswith("https://www.tiktok.com/v2/auth/authorize/?")


def test_identity_flow_never_touches_the_creator_directory(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform, purpose="claim": _fake_config())
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
    monkeypatch.setattr(oauth_module, "config_for", lambda platform, purpose="claim": _fake_config())
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


def test_identity_callback_logs_a_structured_audit_line(client, monkeypatch, caplog):
    """The only durable record of a connect event -- nothing is persisted
    server-side (see SenderIdentityStore.swift) -- so this line has to
    actually carry the facts an audit trail needs: who, which platform,
    the platform's own durable id (not just the handle), and when."""
    monkeypatch.setattr(oauth_module, "config_for", lambda platform, purpose="claim": _fake_config())
    start = client.post("/v1/oauth/tiktok/identity/start")
    state = dict(part.split("=", 1) for part in
                start.json()["authorize_url"].split("?", 1)[1].split("&"))["state"]

    async def fake_exchange(config, code):
        return "sender_handle", "999"
    monkeypatch.setattr(oauth_module, "exchange_code", fake_exchange)

    with caplog.at_level("INFO"):
        client.get("/v1/oauth/tiktok/identity/callback",
                   params={"code": "auth-code", "state": state}, follow_redirects=False)

    import json
    lines = [json.loads(record.message) for record in caplog.records
             if record.message.startswith("{")]
    assert len(lines) == 1
    assert lines[0]["event"] == "identity_connected"
    assert lines[0]["platform"] == "tiktok"
    assert lines[0]["username"] == "sender_handle"
    assert lines[0]["platform_user_id"] == "999"
    assert "timestamp" in lines[0]


def test_claim_and_identity_flows_use_separate_redirect_uris(monkeypatch):
    """The bug this guards against: both flows share one client id/secret,
    but the platform redirects the browser to a single, fixed URL with no
    way to say which flow it came from -- so pointing both at the same
    configured URI means one flow's callback route is simply never reached.
    Confirmed by reading both callback handlers before this test was
    written: each only checks its own pending-state dict."""
    monkeypatch.setenv("TIKTOK_CLIENT_KEY", "id")
    monkeypatch.setenv("TIKTOK_CLIENT_SECRET", "secret")
    monkeypatch.setenv("TIKTOK_REDIRECT_URI", "https://registry.example/v1/oauth/tiktok/callback")
    monkeypatch.setenv("TIKTOK_IDENTITY_REDIRECT_URI",
                       "https://registry.example/v1/oauth/tiktok/identity/callback")

    claim_config = oauth_module.config_for("tiktok")
    identity_config = oauth_module.config_for("tiktok", purpose="identity")
    assert claim_config.redirect_uri == "https://registry.example/v1/oauth/tiktok/callback"
    assert identity_config.redirect_uri == "https://registry.example/v1/oauth/tiktok/identity/callback"
    assert claim_config.redirect_uri != identity_config.redirect_uri


def test_identity_config_is_none_without_its_own_redirect_uri(monkeypatch):
    """Setting only the claim redirect URI must not silently let the
    identity flow start with it -- that's exactly the bug being fixed."""
    monkeypatch.setenv("TIKTOK_CLIENT_KEY", "id")
    monkeypatch.setenv("TIKTOK_CLIENT_SECRET", "secret")
    monkeypatch.setenv("TIKTOK_REDIRECT_URI", "https://registry.example/v1/oauth/tiktok/callback")
    monkeypatch.delenv("TIKTOK_IDENTITY_REDIRECT_URI", raising=False)

    assert oauth_module.config_for("tiktok") is not None
    assert oauth_module.config_for("tiktok", purpose="identity") is None
