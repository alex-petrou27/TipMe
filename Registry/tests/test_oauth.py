"""Platform sign-in verification.

Never talks to real Instagram/TikTok servers — `oauth.config_for` and
`oauth.exchange_code` are monkeypatched so these tests exercise the
registry's own logic (state handling, username matching, session handoff)
without a network dependency.
"""
import time

import pytest

from tipme_registry import oauth as oauth_module


def _fake_config(client_id="test-client-id"):
    return oauth_module.PlatformOAuthConfig(
        platform="instagram",
        client_id=client_id,
        client_secret="test-secret",
        redirect_uri="https://registry.example/v1/oauth/instagram/callback",
        authorize_base="https://www.instagram.com/oauth/authorize",
        scope="instagram_business_basic",
    )


def test_start_without_configured_platform_fails_closed(client):
    response = client.post("/v1/oauth/instagram/start", json={
        "platform": "instagram",
        "username": "creator",
        "lightning_address": "creator@getalby.com",
    })
    assert response.status_code == 503


def test_start_returns_authorize_url_once_configured(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())

    response = client.post("/v1/oauth/instagram/start", json={
        "platform": "instagram",
        "username": "creator",
        "lightning_address": "creator@getalby.com",
    })
    assert response.status_code == 200
    body = response.json()
    assert body["authorize_url"].startswith("https://www.instagram.com/oauth/authorize?")
    assert "state=" in body["authorize_url"]


def test_start_rejects_platform_mismatch(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.post("/v1/oauth/instagram/start", json={
        "platform": "tiktok",
        "username": "creator",
        "lightning_address": "creator@getalby.com",
    })
    assert response.status_code == 400


def test_start_rejects_invalid_handle(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.post("/v1/oauth/instagram/start", json={
        "platform": "instagram",
        "username": "not a real handle!!",
        "lightning_address": "creator@getalby.com",
    })
    assert response.status_code == 400


def _start(client, monkeypatch, username="creator"):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.post("/v1/oauth/instagram/start", json={
        "platform": "instagram",
        "username": username,
        "lightning_address": "creator@getalby.com",
        "preferred_asset": "bitcoin",
    })
    assert response.status_code == 200
    url = response.json()["authorize_url"]
    state = dict(part.split("=", 1) for part in url.split("?", 1)[1].split("&"))["state"]
    return state


def _redirect_params(response):
    location = response.headers["location"]
    query = location.split("?", 1)[1]
    return dict(
        (key, value.replace("+", " "))
        for key, value in (part.split("=", 1) for part in query.split("&"))
    )


def test_callback_verifies_and_marks_record(client, monkeypatch):
    state = _start(client, monkeypatch)

    async def fake_exchange(config, code):
        assert code == "auth-code"
        return "creator", "1234567890"

    monkeypatch.setattr(oauth_module, "exchange_code", fake_exchange)

    response = client.get(
        "/v1/oauth/instagram/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )
    assert response.status_code in (302, 307)
    params = _redirect_params(response)
    assert params["status"] == "success"
    assert params["username"] == "creator"
    session_id = params["session_id"]

    session = client.get(f"/v1/oauth/session/{session_id}")
    assert session.status_code == 200
    body = session.json()
    assert body["verified"] is True
    assert body["management_token"]
    assert body["lightning_address"] == "creator@getalby.com"

    # Burned after one read.
    assert client.get(f"/v1/oauth/session/{session_id}").status_code == 404

    lookup = client.get("/v1/creators/instagram/creator")
    assert lookup.status_code == 200


def test_callback_rejects_username_mismatch(client, monkeypatch):
    state = _start(client, monkeypatch)

    async def fake_exchange(config, code):
        return "someone-else", "999"

    monkeypatch.setattr(oauth_module, "exchange_code", fake_exchange)

    response = client.get(
        "/v1/oauth/instagram/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )
    params = _redirect_params(response)
    assert params["status"] == "error"
    assert params["reason"] == "account_mismatch"


def test_callback_rejects_unknown_state(client, monkeypatch):
    monkeypatch.setattr(oauth_module, "config_for", lambda platform: _fake_config())
    response = client.get(
        "/v1/oauth/instagram/callback",
        params={"code": "auth-code", "state": "not-a-real-state"},
        follow_redirects=False,
    )
    params = _redirect_params(response)
    assert params["status"] == "error"
    assert params["reason"] == "expired_or_invalid_state"


def test_callback_passes_through_platform_denial(client, monkeypatch):
    response = client.get(
        "/v1/oauth/instagram/callback",
        params={"error": "access_denied"},
        follow_redirects=False,
    )
    params = _redirect_params(response)
    assert params["status"] == "error"
    assert params["reason"] == "access_denied"


def test_oauth_verification_can_overwrite_a_squatted_handle(client, monkeypatch):
    """Someone else registered `creator` first, unverified, pointing at their
    own wallet. A real Instagram sign-in as `creator` must be able to fix
    that without needing the squatter's management token — that is the
    entire point of platform sign-in over the bio-code path."""
    squat = client.post("/v1/creators", json={
        "platform": "instagram",
        "username": "creator",
        "lightning_address": "squatter@getalby.com",
    })
    assert squat.status_code == 201
    assert squat.json()["verified"] is False

    state = _start(client, monkeypatch)

    async def fake_exchange(config, code):
        return "creator", "42"

    monkeypatch.setattr(oauth_module, "exchange_code", fake_exchange)

    callback = client.get(
        "/v1/oauth/instagram/callback",
        params={"code": "auth-code", "state": state},
        follow_redirects=False,
    )
    params = _redirect_params(callback)
    assert params["status"] == "success"
    # A second claim, so no fresh management token was minted — the session
    # still reports the real creator's chosen lightning address as active.
    session = client.get(f"/v1/oauth/session/{params['session_id']}").json()
    assert session["lightning_address"] == "creator@getalby.com"
