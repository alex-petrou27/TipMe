"""Platform OAuth: proves a creator controls the Instagram/TikTok handle they
are claiming, so a record can be marked verified without a human checking a
bio code.

The flow is the standard OAuth2 authorization-code exchange, done entirely
server-side so a client secret never ships inside the iOS app binary:

  1. The app asks us for an authorize URL (``/v1/oauth/{platform}/start``).
  2. The user authenticates with Instagram/TikTok in a browser and is
     redirected back to *this service* — never directly to the app — with a
     one-time ``code``.
  3. We exchange that code for an access token and call the platform's own
     "who am I" endpoint, so the username comes from the platform, not from
     whatever the creator typed into the registration form.
  4. Only if that username matches the handle being claimed do we mark the
     record verified.

Platform reality, so nobody is surprised later:

  * **Instagram** — OAuth login only exists for Business/Creator accounts.
    Meta retired personal-account login when it deprecated the Instagram
    Basic Display API. A creator on a personal account still needs the
    manual bio-code path (``POST /v1/creators/{platform}/{username}/verify``,
    admin-checked).
  * **TikTok** — Login Kit works for any account type, but a newly registered
    app is capped to its own sandbox testers until TikTok approves it for
    production use of the ``user.info.basic`` scope.

Neither of those is something this code can fix. What it needs to actually run
is a real Meta app (Instagram product, Business Login) and/or a real TikTok
developer app, each with its client id/secret and this service's own
``/v1/oauth/{platform}/callback`` URL registered as the redirect URI — see
README. Until those environment variables are set, ``config_for`` returns
``None`` and the ``/start`` endpoint fails closed with a 503 rather than
pretending to offer a sign-in that cannot complete.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

import httpx


class OAuthError(Exception):
    """The exchange reached the platform but did not yield a usable identity."""


@dataclass(frozen=True)
class PlatformOAuthConfig:
    platform: str
    client_id: str
    client_secret: str
    redirect_uri: str
    authorize_base: str
    scope: str


def _env(name: str) -> str | None:
    value = os.environ.get(name)
    return value if value else None


def _instagram_config() -> PlatformOAuthConfig | None:
    client_id = _env("INSTAGRAM_CLIENT_ID")
    client_secret = _env("INSTAGRAM_CLIENT_SECRET")
    redirect_uri = _env("INSTAGRAM_REDIRECT_URI")
    if not (client_id and client_secret and redirect_uri):
        return None
    return PlatformOAuthConfig(
        platform="instagram",
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        authorize_base="https://www.instagram.com/oauth/authorize",
        scope="instagram_business_basic",
    )


def _tiktok_config() -> PlatformOAuthConfig | None:
    client_id = _env("TIKTOK_CLIENT_KEY")
    client_secret = _env("TIKTOK_CLIENT_SECRET")
    redirect_uri = _env("TIKTOK_REDIRECT_URI")
    if not (client_id and client_secret and redirect_uri):
        return None
    return PlatformOAuthConfig(
        platform="tiktok",
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        authorize_base="https://www.tiktok.com/v2/auth/authorize/",
        scope="user.info.basic",
    )


def config_for(platform: str) -> PlatformOAuthConfig | None:
    if platform == "instagram":
        return _instagram_config()
    if platform == "tiktok":
        return _tiktok_config()
    return None


def build_authorize_url(config: PlatformOAuthConfig, state: str) -> str:
    params = {
        "client_id" if config.platform == "instagram" else "client_key": config.client_id,
        "redirect_uri": config.redirect_uri,
        "scope": config.scope,
        "response_type": "code",
        "state": state,
    }
    query = httpx.QueryParams(params)
    return f"{config.authorize_base}?{query}"


async def exchange_code(config: PlatformOAuthConfig, code: str) -> tuple[str, str]:
    """Trades an authorization code for the platform's own account identity.

    Returns ``(username, platform_user_id)``. Raises ``OAuthError`` on any
    failure — an expired code, a revoked app, a network error — so the caller
    always has one thing to catch rather than guessing which HTTP exception
    might leak out of a third-party client library.
    """
    if config.platform == "instagram":
        return await _exchange_instagram(config, code)
    return await _exchange_tiktok(config, code)


async def _exchange_instagram(config: PlatformOAuthConfig, code: str) -> tuple[str, str]:
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            token_response = await client.post(
                "https://api.instagram.com/oauth/access_token",
                data={
                    "client_id": config.client_id,
                    "client_secret": config.client_secret,
                    "grant_type": "authorization_code",
                    "redirect_uri": config.redirect_uri,
                    "code": code,
                },
            )
            token_response.raise_for_status()
            token_body = token_response.json()
            access_token = token_body["access_token"]

            profile_response = await client.get(
                "https://graph.instagram.com/v21.0/me",
                params={"fields": "user_id,username", "access_token": access_token},
            )
            profile_response.raise_for_status()
            profile = profile_response.json()
            return profile["username"], str(profile["user_id"])
        except (httpx.HTTPError, KeyError, ValueError) as error:
            raise OAuthError(f"Instagram sign-in did not complete: {error}") from error


async def _exchange_tiktok(config: PlatformOAuthConfig, code: str) -> tuple[str, str]:
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            token_response = await client.post(
                "https://open.tiktokapis.com/v2/oauth/token/",
                data={
                    "client_key": config.client_id,
                    "client_secret": config.client_secret,
                    "grant_type": "authorization_code",
                    "redirect_uri": config.redirect_uri,
                    "code": code,
                },
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            token_response.raise_for_status()
            token_body = token_response.json()
            access_token = token_body["access_token"]

            profile_response = await client.get(
                "https://open.tiktokapis.com/v2/user/info/",
                params={"fields": "open_id,username"},
                headers={"Authorization": f"Bearer {access_token}"},
            )
            profile_response.raise_for_status()
            profile = profile_response.json()
            user = profile["data"]["user"]
            return user["username"], str(user["open_id"])
        except (httpx.HTTPError, KeyError, ValueError) as error:
            raise OAuthError(f"TikTok sign-in did not complete: {error}") from error
