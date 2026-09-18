"""Platform OAuth: proves a creator controls the Instagram/TikTok handle they
are claiming, so a record can be marked verified without a human checking a
bio code. Also backs the identity-only "sending as" connect flow (see
``/v1/oauth/{platform}/identity/start``) for all four platforms below,
including YouTube and X, which the creator-claiming side of this registry
does not otherwise know about (see the doc comment on Swift's ``Platform``
enum for why that split is deliberate).

The flow is the standard OAuth2 authorization-code exchange, done entirely
server-side so a client secret never ships inside the iOS app binary:

  1. The app asks us for an authorize URL (``/v1/oauth/{platform}/start``).
  2. The user authenticates with the platform in a browser and is
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
  * **YouTube** — Google OAuth, Business/Creator distinction does not apply.
    Uses the channel's modern ``@handle`` (``customUrl``), not its opaque
    channel id.
  * **X** — its OAuth 2.0 requires PKCE (a code challenge at ``/authorize``,
    a matching verifier at the token exchange), which is not implemented
    here yet — see the note in ``build_authorize_url`` and
    ``_exchange_x``. Structurally complete and gated behind the same
    ``config_for`` check as every other platform, but will not actually
    complete a real sign-in until that is finished.

None of that is something this code can fix by itself. What it needs to
actually run is a real Meta app (Instagram product, Business Login), a real
TikTok developer app, a Google Cloud OAuth client (YouTube Data API scope),
and/or a real X developer app (once PKCE is added) — each with its client
id/secret and this service's own ``/v1/oauth/{platform}/callback`` URL
registered as the redirect URI — see README. Until those environment
variables are set, ``config_for`` returns ``None`` and the ``/start``
endpoint fails closed with a 503 rather than pretending to offer a sign-in
that cannot complete.
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


def _redirect_uri(prefix: str, *, purpose: str) -> str | None:
    """Two different registry endpoints (`/callback` for claiming a payable
    handle, `/identity/callback` for the "sending as" identity-only badge)
    can share one client id/secret but *cannot* share one redirect URI: the
    platform redirects the browser back to a single literal URL fixed when
    the authorize request is built, with no way for it to know which of our
    two flows started it. Registering only one URI with the platform and
    pointing both flows at it means the second flow's callback route is
    simply never reached -- confirmed by reading both callback handlers,
    each of which only checks its own pending-state dict. So every platform
    needs its identity redirect URI registered and configured separately
    from its claim one, even though both live on the same platform app.
    """
    suffix = "_IDENTITY_REDIRECT_URI" if purpose == "identity" else "_REDIRECT_URI"
    return _env(f"{prefix}{suffix}")


def _instagram_config(*, purpose: str) -> PlatformOAuthConfig | None:
    client_id = _env("INSTAGRAM_CLIENT_ID")
    client_secret = _env("INSTAGRAM_CLIENT_SECRET")
    redirect_uri = _redirect_uri("INSTAGRAM", purpose=purpose)
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


def _tiktok_config(*, purpose: str) -> PlatformOAuthConfig | None:
    client_id = _env("TIKTOK_CLIENT_KEY")
    client_secret = _env("TIKTOK_CLIENT_SECRET")
    redirect_uri = _redirect_uri("TIKTOK", purpose=purpose)
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


def _youtube_config(*, purpose: str) -> PlatformOAuthConfig | None:
    client_id = _env("YOUTUBE_CLIENT_ID")
    client_secret = _env("YOUTUBE_CLIENT_SECRET")
    redirect_uri = _redirect_uri("YOUTUBE", purpose=purpose)
    if not (client_id and client_secret and redirect_uri):
        return None
    return PlatformOAuthConfig(
        platform="youtube",
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        authorize_base="https://accounts.google.com/o/oauth2/v2/auth",
        scope="https://www.googleapis.com/auth/youtube.readonly",
    )


def _x_config(*, purpose: str) -> PlatformOAuthConfig | None:
    client_id = _env("X_CLIENT_ID")
    client_secret = _env("X_CLIENT_SECRET")
    redirect_uri = _redirect_uri("X", purpose=purpose)
    if not (client_id and client_secret and redirect_uri):
        return None
    return PlatformOAuthConfig(
        platform="x",
        client_id=client_id,
        client_secret=client_secret,
        redirect_uri=redirect_uri,
        authorize_base="https://twitter.com/i/oauth2/authorize",
        scope="users.read tweet.read",
    )


def config_for(platform: str, *, purpose: str = "claim") -> PlatformOAuthConfig | None:
    """`purpose` is ``"claim"`` (a creator proving they own the handle they
    are registering a payout wallet for) or ``"identity"`` (a sender just
    proving "this is me," see `oauth_identity_start`). Same platform app,
    same client id/secret either way -- only the redirect URI differs, per
    `_redirect_uri`'s doc comment.
    """
    if platform == "instagram":
        return _instagram_config(purpose=purpose)
    if platform == "tiktok":
        return _tiktok_config(purpose=purpose)
    if platform == "youtube":
        return _youtube_config(purpose=purpose)
    if platform == "x":
        return _x_config(purpose=purpose)
    return None


def build_authorize_url(config: PlatformOAuthConfig, state: str) -> str:
    params = {
        "client_key" if config.platform == "tiktok" else "client_id": config.client_id,
        "redirect_uri": config.redirect_uri,
        "scope": config.scope,
        "response_type": "code",
        "state": state,
    }
    # X's OAuth 2.0 requires PKCE (a code_challenge here, a matching
    # code_verifier at token-exchange time) -- every other platform this
    # registry talks to uses a plain authorization-code exchange without it.
    # Not implemented: this makes the authorize step buildable and the whole
    # flow fail closed the same way an unconfigured platform does (see
    # `config_for`), rather than pretending X is at parity with the others.
    if config.platform == "x":
        params["code_challenge"] = "plain-pkce-not-yet-implemented"
        params["code_challenge_method"] = "plain"
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
    if config.platform == "tiktok":
        return await _exchange_tiktok(config, code)
    if config.platform == "youtube":
        return await _exchange_youtube(config, code)
    return await _exchange_x(config, code)


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


async def _exchange_youtube(config: PlatformOAuthConfig, code: str) -> tuple[str, str]:
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            token_response = await client.post(
                "https://oauth2.googleapis.com/token",
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

            # `mine=true` -- the channel belonging to whoever just signed in,
            # not a channel id we would otherwise have no way to know yet.
            profile_response = await client.get(
                "https://www.googleapis.com/youtube/v3/channels",
                params={"part": "snippet", "mine": "true"},
                headers={"Authorization": f"Bearer {access_token}"},
            )
            profile_response.raise_for_status()
            profile = profile_response.json()
            channel = profile["items"][0]
            # `customUrl` is the modern "@handle" -- what a sender actually
            # types to find this creator -- not the channel's opaque id.
            handle = channel["snippet"]["customUrl"].lstrip("@")
            return handle, str(channel["id"])
        except (httpx.HTTPError, KeyError, IndexError, ValueError) as error:
            raise OAuthError(f"YouTube sign-in did not complete: {error}") from error


async def _exchange_x(config: PlatformOAuthConfig, code: str) -> tuple[str, str]:
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            token_response = await client.post(
                "https://api.twitter.com/2/oauth2/token",
                data={
                    "client_id": config.client_id,
                    "grant_type": "authorization_code",
                    "redirect_uri": config.redirect_uri,
                    "code": code,
                    # See the PKCE note in `build_authorize_url` -- this
                    # verifier does not really match a prior code_challenge
                    # yet, so this call will fail at X until that is wired
                    # up properly. Kept structurally complete rather than
                    # stubbed out, so finishing PKCE later is a small,
                    # localised change instead of writing this from scratch.
                    "code_verifier": "plain-pkce-not-yet-implemented",
                },
                auth=(config.client_id, config.client_secret),
            )
            token_response.raise_for_status()
            token_body = token_response.json()
            access_token = token_body["access_token"]

            profile_response = await client.get(
                "https://api.twitter.com/2/users/me",
                headers={"Authorization": f"Bearer {access_token}"},
            )
            profile_response.raise_for_status()
            profile = profile_response.json()
            user = profile["data"]
            return user["username"], str(user["id"])
        except (httpx.HTTPError, KeyError, ValueError) as error:
            raise OAuthError(f"X sign-in did not complete: {error}") from error
