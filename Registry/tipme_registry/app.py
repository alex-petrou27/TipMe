"""TipMe creator registry HTTP API.

Answers one question for the app: given a TikTok or Instagram handle, where do
this creator's tips go? The link is made once, when the creator onboards, and
persists until they delete it.

Phase 2 note: the Instagram comment-webhook endpoint belongs here too, since it
is HTTP and server-side. See docs/PHASE2.md for the reason that is harder than
it sounds — a server cannot hold a non-custodial sender's keys, so a
server-side trigger cannot itself move a sender's money.
"""
from __future__ import annotations

import json
import logging
import os
import secrets
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, UploadFile, File
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel, Field

from . import accounts, lightning, mailer, oauth, page_metadata, rates as rates_module, signing
from .handles import Handle, InvalidHandle, normalise as normalise_handle
from .storage import Account, CreatorRecord, EmailTaken, InsufficientBalance, Storage

logger = logging.getLogger("tipme_registry.app")

ASSETS = ("bitcoin", "usdt")

# How long a session token stays valid. The app is expected to hold onto it
# and only ask the user to log in again after this, so it needs to be long
# enough that "custodial" doesn't also mean "logs you out constantly."
SESSION_TTL_SECONDS = 60 * 60 * 24 * 30


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

class Settings:
    def __init__(self) -> None:
        self.database_path = os.environ.get("REGISTRY_DATABASE_PATH", "tipme_registry.sqlite3")

        key = os.environ.get("REGISTRY_SIGNING_PRIVATE_KEY")
        if not key:
            raise RuntimeError(
                "REGISTRY_SIGNING_PRIVATE_KEY is not set. Generate a keypair with:\n"
                "  python -m tipme_registry.keygen"
            )
        self.private_key = signing.load_private_key(key)

        # Guards the endpoints that mark a handle verified. Verification is the
        # difference between a tip and a redirect, so it is never self-service.
        self.admin_token = os.environ.get("REGISTRY_ADMIN_TOKEN")

        # Registrations per client per hour. Handle-squatting is cheap without
        # this: a script could claim every popular handle before their owners
        # do, pointing them all at one wallet.
        self.registrations_per_hour = int(os.environ.get("REGISTRY_REGISTRATIONS_PER_HOUR", "10"))

        # Separate from registrations_per_hour above on purpose: claiming a
        # creator handle and opening a money-holding account are different
        # kinds of action, and a bot farming one should not be constrained
        # by (or share a budget with) someone doing a lot of the other.
        self.signups_per_hour = int(os.environ.get("REGISTRY_SIGNUPS_PER_HOUR", "10"))

        # Login attempts per client per hour. A custodial account is only as
        # safe as its password, so brute-forcing one has to be slow.
        self.login_attempts_per_hour = int(os.environ.get("REGISTRY_LOGIN_ATTEMPTS_PER_HOUR", "20"))

        # Forgot-password requests per client per hour. Its own budget,
        # separate from login attempts -- this one can be used to spam a
        # stranger's inbox rather than to brute-force a password, so it is
        # worth limiting even though it can never itself leak a credential.
        self.password_resets_per_hour = int(os.environ.get("REGISTRY_PASSWORD_RESETS_PER_HOUR", "5"))

        # The custom URL scheme the app registers, so the OAuth callback can
        # hand control back to it once Instagram/TikTok redirect here. Not a
        # secret — it is baked into every copy of the app.
        self.app_url_scheme = os.environ.get("TIPME_APP_URL_SCHEME", "tipme")

        # Creator profile photos. Plain files on disk rather than the sqlite
        # database — they are the one piece of a creator record that is purely
        # cosmetic, never read on the payment path, and would bloat every
        # database backup for no safety benefit.
        self.photos_dir = Path(os.environ.get("REGISTRY_PHOTOS_DIR", "photos"))
        self.max_photo_bytes = 2 * 1024 * 1024

        # DEV-ONLY escape hatch: skips verification entirely so payments can
        # be exercised end-to-end while real OAuth is still Tester-gated (see
        # link_creator). This defeats the entire point of verification --
        # anyone could link anyone else's handle and immediately collect
        # their tips -- so it must default off and never be set in an
        # environment that holds real money.
        self.auto_verify_links = os.environ.get("REGISTRY_AUTO_VERIFY_LINKS") == "1"


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


_settings: Settings | None = None
_storage: Storage | None = None

# In-memory sliding window. Adequate for a single process; a multi-process
# deployment needs this moved to shared storage, or the effective limit becomes
# the configured limit multiplied by the worker count.
_registration_attempts: dict[str, deque[float]] = defaultdict(deque)
_signup_attempts: dict[str, deque[float]] = defaultdict(deque)
_login_attempts: dict[str, deque[float]] = defaultdict(deque)
_password_reset_attempts: dict[str, deque[float]] = defaultdict(deque)


@dataclass
class _PendingOAuth:
    """What `/v1/oauth/{platform}/start` remembers between issuing a `state`
    and the platform redirecting back to `/callback` with it. Same
    single-process caveat as `_registration_attempts` above."""
    platform: str
    handle: Handle
    lightning_address: str
    preferred_asset: str
    minimum_tip_minor: int | None
    display_name: str | None
    created_at: float


@dataclass
class _OAuthSession:
    """What a successful callback leaves for the app to collect.

    The callback's final redirect goes through the OS's URL-scheme routing —
    a channel a second app registering the same scheme could in principle
    intercept. So the redirect carries only this opaque, single-use id, never
    the management token itself; the app exchanges the id for the real values
    over a direct HTTPS call to `/v1/oauth/session/{id}`, and the entry is
    deleted the moment it is read.
    """
    handle: Handle
    lightning_address: str
    management_token: str | None
    claim_token: str | None
    created_at: float


@dataclass
class _PendingIdentity:
    """Same idea as `_PendingOAuth`, for a sign-in that only proves who the
    *sender* is — no handle, no wallet, nothing written to `storage`."""
    platform: str
    created_at: float


@dataclass
class _IdentitySession:
    platform: str
    username: str
    created_at: float


_OAUTH_STATE_TTL = 600.0
_OAUTH_SESSION_TTL = 300.0
_oauth_pending: dict[str, _PendingOAuth] = {}
_oauth_sessions: dict[str, _OAuthSession] = {}
_identity_pending: dict[str, _PendingIdentity] = {}
_identity_sessions: dict[str, _IdentitySession] = {}


def _oauth_redirect(scheme: str, platform: str, status: str, **extra: str) -> RedirectResponse:
    """The one place both `/callback` endpoints turn a result into the
    redirect that hands control back to the app."""
    params = {"platform": platform, "status": status, **extra}
    return RedirectResponse(f"{scheme}://oauth-complete?{urlencode(params)}")


def _rate_limit_registration(client: str, settings: Settings) -> None:
    window = 3600.0
    now = time.monotonic()
    attempts = _registration_attempts[client]
    while attempts and now - attempts[0] > window:
        attempts.popleft()
    if len(attempts) >= settings.registrations_per_hour:
        raise HTTPException(
            status_code=429,
            detail="Too many registrations from this address. Try again later.",
        )
    attempts.append(now)


def _rate_limit_signup(client: str, settings: Settings) -> None:
    window = 3600.0
    now = time.monotonic()
    attempts = _signup_attempts[client]
    while attempts and now - attempts[0] > window:
        attempts.popleft()
    if len(attempts) >= settings.signups_per_hour:
        raise HTTPException(
            status_code=429,
            detail="Too many accounts created from this address. Try again later.",
        )
    attempts.append(now)


def _rate_limit_login(client: str, settings: Settings) -> None:
    window = 3600.0
    now = time.monotonic()
    attempts = _login_attempts[client]
    while attempts and now - attempts[0] > window:
        attempts.popleft()
    if len(attempts) >= settings.login_attempts_per_hour:
        raise HTTPException(
            status_code=429,
            detail="Too many login attempts from this address. Try again later.",
        )
    attempts.append(now)


def _rate_limit_password_reset(client: str, settings: Settings) -> None:
    window = 3600.0
    now = time.monotonic()
    attempts = _password_reset_attempts[client]
    while attempts and now - attempts[0] > window:
        attempts.popleft()
    if len(attempts) >= settings.password_resets_per_hour:
        raise HTTPException(
            status_code=429,
            detail="Too many reset requests from this address. Try again later.",
        )
    attempts.append(now)


def get_storage(settings: Settings = Depends(get_settings)) -> Storage:
    global _storage
    if _storage is None:
        _storage = Storage(settings.database_path)
    return _storage


def get_current_user(
    authorization: str | None = Header(default=None),
    storage: Storage = Depends(get_storage),
) -> str:
    """Resolves a ``Bearer <token>`` header to a user id.

    Every balance-affecting endpoint depends on this rather than trusting an
    id the client sends directly -- a user id in the request body would let
    anyone move money out of any account just by guessing or copying one.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    user_id = storage.session_user_id(token)
    if user_id is None:
        raise HTTPException(status_code=401, detail="invalid or expired session")
    return user_id


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------

class RegisterRequest(BaseModel):
    platform: str
    username: str
    lightning_address: str
    preferred_asset: str = "bitcoin"
    minimum_tip_minor_units: int | None = Field(default=None, ge=0)
    display_name: str | None = None


class RegisterResponse(BaseModel):
    platform: str
    username: str
    lightning_address: str
    verified: bool
    claim_token: str
    verification_instructions: str
    # Returned only when the handle is claimed for the first time. Required to
    # change the record afterwards, so the creator must keep it.
    management_token: str | None = None


class OAuthStartRequest(BaseModel):
    platform: str
    username: str
    lightning_address: str
    preferred_asset: str = "bitcoin"
    minimum_tip_minor_units: int | None = Field(default=None, ge=0)
    display_name: str | None = None


class OAuthStartResponse(BaseModel):
    authorize_url: str
    expires_in: int


class OAuthSessionResponse(BaseModel):
    platform: str
    username: str
    lightning_address: str
    verified: bool
    claim_token: str | None
    management_token: str | None


class SignupRequest(BaseModel):
    email: str
    password: str


class LoginRequest(BaseModel):
    email: str
    password: str


class AuthResponse(BaseModel):
    user_id: str
    email: str
    session_token: str


class ForgotPasswordRequest(BaseModel):
    email: str


class ResetPasswordRequest(BaseModel):
    code: str
    new_password: str


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str


class BalanceEntry(BaseModel):
    asset: str
    balance_minor: int


class LinkCreatorRequest(BaseModel):
    platform: str
    username: str
    preferred_asset: str = "bitcoin"
    minimum_tip_minor_units: int | None = Field(default=None, ge=0)
    display_name: str | None = None


class LinkCreatorResponse(BaseModel):
    platform: str
    username: str
    preferred_asset: str
    verified: bool
    claim_token: str
    verification_instructions: str


class VerifyByLinkRequest(BaseModel):
    post_url: str


class TipRequest(BaseModel):
    platform: str
    username: str
    asset: str
    amount_minor_units: int = Field(gt=0)


class TipResponse(BaseModel):
    platform: str
    username: str
    asset: str
    amount_minor_units: int
    new_balance_minor_units: int


class MeResponse(BaseModel):
    user_id: str
    email: str
    balances: list[BalanceEntry]


class RatesResponse(BaseModel):
    currency: str
    # Fiat major units (e.g. pounds, not pence) per one whole coin. The
    # client scales this down to a per-sat / per-cent price itself, the same
    # way it already did with rates from the Breez SDK.
    bitcoin_price: float
    usdt_price: float
    as_of: str


# --------------------------------------------------------------------------
# App
# --------------------------------------------------------------------------

app = FastAPI(title="TipMe creator registry", version="0.1.0")


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/v1/public-key")
def public_key(settings: Settings = Depends(get_settings)) -> dict:
    """The key the app pins as TIPME_REGISTRY_PUBLIC_KEY.

    Served for convenience during setup only. The app must ship with this value
    baked in — fetching it at runtime from the same server whose responses it
    authenticates would defeat the entire point of signing them.
    """
    return {"public_key": signing.public_key_b64(settings.private_key)}


@app.post("/v1/auth/signup", response_model=AuthResponse, status_code=201)
def signup(
    request: SignupRequest,
    http_request: Request,
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> AuthResponse:
    try:
        email = accounts.normalise_email(request.email)
    except accounts.InvalidEmail as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    try:
        accounts.validate_password(request.password)
    except accounts.WeakPassword as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    _rate_limit_signup(_client_key(http_request), settings)

    try:
        account = storage.create_user(email, accounts.hash_password(request.password))
    except EmailTaken as error:
        raise HTTPException(status_code=409, detail=str(error)) from error

    token = storage.create_session(account.id, SESSION_TTL_SECONDS)
    return AuthResponse(user_id=account.id, email=account.email, session_token=token)


@app.post("/v1/auth/login", response_model=AuthResponse)
def login(
    request: LoginRequest,
    http_request: Request,
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> AuthResponse:
    _rate_limit_login(_client_key(http_request), settings)

    # Same "invalid email or password" message either way -- confirming
    # which emails have accounts is its own small leak, and this endpoint
    # has no reason to offer it.
    invalid = HTTPException(status_code=401, detail="invalid email or password")
    try:
        email = accounts.normalise_email(request.email)
    except accounts.InvalidEmail:
        raise invalid

    found = storage.get_user_by_email(email)
    if found is None:
        raise invalid
    account, password_hash = found
    if not accounts.verify_password(request.password, password_hash):
        raise invalid

    token = storage.create_session(account.id, SESSION_TTL_SECONDS)
    return AuthResponse(user_id=account.id, email=account.email, session_token=token)


@app.post("/v1/auth/logout", status_code=204)
def logout(
    authorization: str | None = Header(default=None),
    storage: Storage = Depends(get_storage),
) -> Response:
    # Deliberately does not go through get_current_user: an already-expired
    # or already-logged-out token should still result in "you are logged
    # out," not a 401 for a client that is trying to do exactly that.
    if authorization and authorization.startswith("Bearer "):
        storage.delete_session(authorization.removeprefix("Bearer ").strip())
    return Response(status_code=204)


_PASSWORD_RESET_TTL_SECONDS = 30 * 60


@app.post("/v1/auth/forgot-password", status_code=204)
def forgot_password(
    request: ForgotPasswordRequest,
    http_request: Request,
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> Response:
    """Always answers 204, whether or not the email has an account.

    Confirming which emails are registered is its own small leak (the same
    reasoning `login`'s identical error message follows) -- worse here,
    since this endpoint takes no password at all, so answering differently
    would let anyone enumerate real accounts for free.
    """
    _rate_limit_password_reset(_client_key(http_request), settings)

    try:
        email = accounts.normalise_email(request.email)
    except accounts.InvalidEmail:
        return Response(status_code=204)

    found = storage.get_user_by_email(email)
    if found is not None:
        account, _ = found
        code = storage.create_password_reset(account.id, _PASSWORD_RESET_TTL_SECONDS)
        mailer.send_password_reset(email, code)
    return Response(status_code=204)


@app.post("/v1/auth/reset-password", response_model=AuthResponse)
def reset_password(
    request: ResetPasswordRequest,
    storage: Storage = Depends(get_storage),
) -> AuthResponse:
    try:
        accounts.validate_password(request.new_password)
    except accounts.WeakPassword as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    invalid = HTTPException(status_code=400, detail="That reset code is invalid or has expired.")
    user_id = storage.consume_password_reset(request.code.strip().upper())
    if user_id is None:
        raise invalid
    account = storage.get_user(user_id)
    if account is None:
        raise invalid

    storage.update_password(user_id, accounts.hash_password(request.new_password))
    # A reset is, by definition, happening because the old password is no
    # longer trusted -- every session it could have created should stop
    # working too, not just future login attempts.
    storage.delete_sessions_for_user(user_id)

    token = storage.create_session(user_id, SESSION_TTL_SECONDS)
    return AuthResponse(user_id=account.id, email=account.email, session_token=token)


@app.post("/v1/auth/change-password", status_code=204)
def change_password(
    request: ChangePasswordRequest,
    authorization: str | None = Header(default=None),
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> Response:
    account = storage.get_user(user_id)
    found = storage.get_user_by_email(account.email) if account else None
    if account is None or found is None:
        raise HTTPException(status_code=401, detail="invalid or expired session")
    _, password_hash = found

    if not accounts.verify_password(request.current_password, password_hash):
        raise HTTPException(status_code=403, detail="Current password is incorrect.")
    try:
        accounts.validate_password(request.new_password)
    except accounts.WeakPassword as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    storage.update_password(user_id, accounts.hash_password(request.new_password))
    # Keep the session that just proved the old password alive; every other
    # one (a lost or stolen device, say) stops working immediately.
    current_token = authorization.removeprefix("Bearer ").strip() if authorization else None
    storage.delete_sessions_for_user(user_id, except_token=current_token)
    return Response(status_code=204)


@app.get("/v1/me", response_model=MeResponse)
def me(
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> MeResponse:
    account = storage.get_user(user_id)
    if account is None:
        # The session outlived the account it points at -- possible only if
        # an account is deleted without its sessions being cleaned up first.
        raise HTTPException(status_code=401, detail="invalid or expired session")
    balances = storage.get_balances(user_id)
    return MeResponse(
        user_id=account.id,
        email=account.email,
        balances=[
            BalanceEntry(asset=asset, balance_minor=balances.get(asset, 0))
            for asset in ASSETS
        ],
    )


@app.post("/v1/me/creators", response_model=LinkCreatorResponse, status_code=201)
def link_creator(
    request: LinkCreatorRequest,
    user_id: str = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> LinkCreatorResponse:
    """Links a social handle straight to the signed-in account's own
    balance -- the "tip a friend who already has TipMe" path, distinct from
    `POST /v1/creators`'s anonymous claim against an external Lightning
    address. See `Storage.link_to_tipme_account` for what that changes
    about how a tip to this handle settles.

    An unverified claim only reserves the handle *provisionally*: it does
    not block someone else (including the real account owner) from
    claiming it instead, and `POST /v1/me/tip` refuses to deliver money to
    it. Self-service linking never proved you control the social account --
    only a verified claim should be able to lock a handle away from its
    real owner or actually collect tips. See `verify` below for how a claim
    becomes verified.
    """
    try:
        handle = normalise_handle(request.platform, request.username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    if request.preferred_asset not in ASSETS:
        raise HTTPException(
            status_code=400,
            detail=f"preferred_asset must be one of {', '.join(ASSETS)}",
        )

    existing = storage.get(handle)
    if existing is not None and existing.tipme_user_id != user_id and existing.verified:
        # A *verified* claim by someone else is a real, proven ownership --
        # that one stays locked, same as `_authorise_update` protects a
        # verified external-address registration. An unverified claim has
        # no such proof behind it, so it is not exclusive: falling through
        # here lets this call overwrite it, which is exactly how the real
        # owner takes their handle back from a squatter.
        raise HTTPException(
            status_code=403,
            detail="This handle is already verified and linked elsewhere. Contact support.",
        )

    token = f"tipme-verify-{secrets.token_urlsafe(8)}"
    record = storage.link_to_tipme_account(
        handle=handle,
        user_id=user_id,
        preferred_asset=request.preferred_asset,
        minimum_tip_minor=request.minimum_tip_minor_units,
        display_name=request.display_name,
        claim_token=token,
    )

    if settings.auto_verify_links:
        record = storage.set_verified(handle, True, via="dev-auto") or record

    return LinkCreatorResponse(
        platform=record.platform,
        username=record.username,
        preferred_asset=record.preferred_asset,
        verified=record.verified,
        claim_token=token,
        verification_instructions=(
            "Auto-verified for testing (REGISTRY_AUTO_VERIFY_LINKS=1) -- turn this off "
            "before anyone outside your team can link a handle." if settings.auto_verify_links else
            f"Add '{token}' to your {handle.platform} bio, then contact support to "
            "get verified. Tips can't reach this handle until then, and until "
            "then someone else can also claim it."
        ),
    )


@app.delete("/v1/me/creators/{platform}/{username}", status_code=204)
def unlink_own_creator(
    platform: str,
    username: str,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> Response:
    """Convenience alias for `DELETE /v1/creators/{platform}/{username}`
    scoped to "whatever I'm signed in as," so the app does not need to hold
    a management token that a TipMe-account-linked handle never had in the
    first place -- the session already proves ownership."""
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    record = storage.get(handle)
    if record is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    if record.tipme_user_id != user_id:
        raise HTTPException(status_code=403, detail="This handle isn't linked to your account.")
    storage.delete(handle)
    return Response(status_code=204)


@app.post("/v1/me/creators/{platform}/{username}/request-verification")
def request_verification(
    platform: str,
    username: str,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> dict:
    """Lets the creator say "I've put the code in my bio, please check" --
    the self-service half of the manual bio-code path. `POST
    /v1/creators/{platform}/{username}/verify` itself stays admin-only on
    purpose (see its docstring): nothing here can prove ownership by
    itself, so this doesn't verify anything -- it just puts the claim in
    front of whoever holds the admin token, the same way the dev
    password-reset flow logs a code instead of emailing one (see
    mailer.py). Swapping this for a real review queue later doesn't change
    the app-facing contract.
    """
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    record = storage.get(handle)
    if record is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    if record.tipme_user_id != user_id:
        raise HTTPException(status_code=403, detail="This handle isn't linked to your account.")
    if record.verified:
        return {"status": "already_verified"}

    claim_token = storage.claim_token(handle)
    profile_url = (
        f"https://instagram.com/{handle.username}" if handle.platform == "instagram"
        else f"https://www.tiktok.com/@{handle.username}"
    )
    logger.warning(
        "[VERIFICATION REQUESTED] %s says the bio code is live -- check %s for "
        "'%s', then POST /v1/creators/%s/%s/verify with the admin token.",
        handle.key, profile_url, claim_token, handle.platform, handle.username,
    )
    return {"status": "requested"}


_ALLOWED_POST_URL_PREFIXES = (
    "https://www.instagram.com/", "https://instagram.com/",
    "https://www.tiktok.com/", "https://vm.tiktok.com/",
)


@app.post("/v1/me/creators/{platform}/{username}/verify-by-link")
async def verify_by_link(
    platform: str,
    username: str,
    request: VerifyByLinkRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> dict:
    """Automated verification: fetches a public post the creator says
    contains their claim code, the same way any link-preview feature reads
    a shared URL, and only verifies if the code is genuinely there. See
    `page_metadata.py` for why this is a legitimate fetch and not scraping
    -- it only ever touches one URL the signed-in creator handed us, never
    a profile the app goes looking at on its own.

    This never trusts the client's word for what it saw -- the client only
    supplies the URL; the registry does its own fetch and its own check,
    the same trust boundary `send_tip` uses for money.
    """
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    record = storage.get(handle)
    if record is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    if record.tipme_user_id != user_id:
        raise HTTPException(status_code=403, detail="This handle isn't linked to your account.")
    if record.verified:
        return {"status": "already_verified"}

    if not request.post_url.startswith(_ALLOWED_POST_URL_PREFIXES):
        raise HTTPException(status_code=400, detail="That doesn't look like an Instagram or TikTok link.")

    claim_token = storage.claim_token(handle)
    try:
        metadata = await page_metadata.fetch(request.post_url)
    except page_metadata.PageFetchError as error:
        raise HTTPException(status_code=502, detail=f"Couldn't fetch that link: {error}") from error

    if not claim_token or not metadata.contains(claim_token):
        raise HTTPException(
            status_code=400,
            detail="That post's caption doesn't contain your verification code. "
                   "Make sure the post is public and the code is in the caption itself.",
        )

    updated = storage.set_verified(handle, True, via="link")
    return {"status": "verified", "verified": updated.verified if updated else True}


@app.post("/v1/me/creators/{platform}/{username}/verify-by-bio")
async def verify_by_bio(
    platform: str,
    username: str,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> dict:
    """One-tap verification: fetches the creator's own public profile page
    and checks the standard `<meta name="description">` tag Instagram
    fills with the real bio text -- confirmed by fetching real accounts
    (see `page_metadata.py`), not assumed. No link to paste: the profile
    URL is built from the handle this record already carries.

    Instagram-only for now. TikTok's profile page, fetched the same
    legitimate way, does not serve bio text to an unauthenticated request
    at all (confirmed by fetching one directly) -- `verify-by-link`
    (checking a post's caption instead) is the automated option there.
    """
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    if handle.platform != "instagram":
        raise HTTPException(
            status_code=400,
            detail="Bio verification only works for Instagram right now -- TikTok's profile "
                   "page doesn't expose bio text to this kind of check. Use a post link instead.",
        )

    record = storage.get(handle)
    if record is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    if record.tipme_user_id != user_id:
        raise HTTPException(status_code=403, detail="This handle isn't linked to your account.")
    if record.verified:
        return {"status": "already_verified"}

    claim_token = storage.claim_token(handle)
    profile_url = f"https://www.instagram.com/{handle.username}/"
    try:
        metadata = await page_metadata.fetch(profile_url)
    except page_metadata.PageFetchError as error:
        raise HTTPException(status_code=502, detail=f"Couldn't fetch your profile: {error}") from error

    if not claim_token or not metadata.contains(claim_token):
        raise HTTPException(
            status_code=400,
            detail="Your bio doesn't contain your verification code yet, or your profile "
                   "isn't public. Add the code to your bio and try again.",
        )

    updated = storage.set_verified(handle, True, via="link")
    return {"status": "verified", "verified": updated.verified if updated else True}


@app.post("/v1/me/tip", response_model=TipResponse)
def send_tip(
    request: TipRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> TipResponse:
    """The one payment path that actually moves money today.

    Only works when the destination handle is linked to a TipMe account
    (see `link_creator` above) -- that is what makes this safe to implement
    now rather than waiting on the real external-send wallet: the whole
    transfer is two rows changing in this database, atomically, via
    `Storage.transfer_balance`. A handle registered against an external
    Lightning address instead is refused here with a clear reason, not a
    silent no-op.

    Also requires the destination to be verified. An unverified link is
    just someone's unproven claim to a handle -- paying it out would make
    squatting a real handle (claim it, collect tips meant for its actual
    owner) profitable. Verification is what turns "someone typed this
    handle into a form" into "the person who controls this handle asked
    for this."
    """
    try:
        handle = normalise_handle(request.platform, request.username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    if request.asset not in ASSETS:
        raise HTTPException(status_code=400, detail=f"asset must be one of {', '.join(ASSETS)}")

    record = storage.get(handle)
    if record is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    if record.tipme_user_id is None:
        raise HTTPException(
            status_code=400,
            detail="This creator hasn't linked their handle to a TipMe account yet, "
                   "so TipMe can't deliver a tip to them directly.",
        )
    if record.tipme_user_id == user_id:
        raise HTTPException(status_code=400, detail="You can't tip your own linked handle.")
    if not record.verified:
        raise HTTPException(
            status_code=403,
            detail="This creator hasn't verified their handle yet, so TipMe can't "
                   "safely deliver a tip to them -- see docs/PHASE2.md for how they verify.",
        )

    try:
        storage.transfer_balance(
            from_user_id=user_id,
            to_user_id=record.tipme_user_id,
            asset=request.asset,
            amount_minor=request.amount_minor_units,
            reason="tip",
            from_counterparty=f"{handle.platform}:{handle.username}",
            to_counterparty=f"user:{user_id}",
        )
    except InsufficientBalance as error:
        raise HTTPException(status_code=402, detail=str(error)) from error

    new_balance = storage.get_balances(user_id).get(request.asset, 0)
    return TipResponse(
        platform=record.platform,
        username=record.username,
        asset=request.asset,
        amount_minor_units=request.amount_minor_units,
        new_balance_minor_units=new_balance,
    )


@app.get("/v1/rates", response_model=RatesResponse)
async def get_rates(currency: str = "GBP") -> RatesResponse:
    try:
        bitcoin_price, usdt_price = await rates_module.get(currency)
    except rates_module.RateUnavailable as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    return RatesResponse(
        currency=currency.upper(),
        bitcoin_price=bitcoin_price,
        usdt_price=usdt_price,
        as_of=signing.iso8601(datetime.now(timezone.utc)),
    )


@app.get("/v1/creators/{platform}/{username}")
def lookup(
    platform: str,
    username: str,
    response: Response,
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> dict:
    """Signed handle -> wallet lookup. This is the hot path for every tip."""
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    record = storage.get(handle)
    if record is None:
        # A plain 404 is the expected, common answer: most creators have not
        # signed up. The client turns this into a manual-entry offer, not an
        # error screen.
        raise HTTPException(status_code=404, detail="creator not registered")

    # Responses are individually signed and short-lived, so they must not be
    # cached by an intermediary past their freshness window.
    response.headers["Cache-Control"] = "no-store"
    return _signed_payload(record, settings)


def _signed_payload(record: CreatorRecord, settings: Settings) -> dict:
    now = datetime.now(timezone.utc)
    payload = {
        "platform": record.platform,
        "username": record.username,
        "lightning_address": record.lightning_address,
        # Present only for a handle linked straight to a TipMe account's own
        # balance (see POST /v1/me/creators) -- signed for integrity exactly
        # like lightning_address, since this is just as much "where the
        # money goes" as that field is. A sender's app must treat this as
        # the destination whenever it is non-null, never fall back to
        # lightning_address for a record that has it.
        "tipme_user_id": record.tipme_user_id,
        "preferred_asset": record.preferred_asset,
        "minimum_tip_minor_units": record.minimum_tip_minor,
        "display_name": record.display_name,
        "verified": record.verified,
        # Not itself signed-for-integrity the way the payment fields are — the
        # image bytes ride a separate, ordinary HTTPS GET. This just tells the
        # client whether that GET is worth making. Cosmetic only; nothing on
        # the payment path reads it.
        "has_photo": _photo_path(record.platform, record.username, settings) is not None,
        "updated_at": signing.iso8601(record.updated_at),
        # Signed-at is what makes a captured response un-replayable after a
        # creator has moved wallet; the client rejects anything too old.
        "signed_at": signing.iso8601(now),
    }
    return signing.sign_payload(settings.private_key, payload)


_PHOTO_EXTENSIONS = (("jpg", "image/jpeg"), ("png", "image/png"))


def _photo_path(platform: str, username: str, settings: Settings) -> Path | None:
    """The stored photo for a handle, if any — checked by file existence
    rather than a database column, since the file *is* the source of truth."""
    for extension, _media_type in _PHOTO_EXTENSIONS:
        path = settings.photos_dir / f"{platform}_{username}.{extension}"
        if path.exists():
            return path
    return None


@app.post("/v1/creators", response_model=RegisterResponse, status_code=201)
def register(
    request: RegisterRequest,
    http_request: Request,
    x_management_token: str | None = Header(default=None),
    x_admin_token: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> RegisterResponse:
    """Creator onboarding: link a handle to a wallet.

    Claiming an *unclaimed* handle is open — there is no identity to check
    against yet, which is why a fresh record is always unverified and the app
    labels it as such.

    Changing an *existing* record is not open. Without that distinction anyone
    could re-register a registered creator's handle, point it at their own
    wallet, and collect that creator's tips; clearing the verified flag would
    warn users but would not stop the payment. So updates require the
    management token issued at first registration (or the admin token).
    """
    try:
        handle = normalise_handle(request.platform, request.username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    try:
        address = lightning.normalise(request.lightning_address)
    except lightning.InvalidLightningAddress as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    if request.preferred_asset not in ASSETS:
        raise HTTPException(
            status_code=400,
            detail=f"preferred_asset must be one of {', '.join(ASSETS)}",
        )

    existing = storage.get(handle)
    is_new_claim = existing is None

    if is_new_claim:
        _rate_limit_registration(_client_key(http_request), settings)
        management_token = f"tipme-manage-{secrets.token_urlsafe(24)}"
    else:
        _authorise_update(handle, storage, x_management_token, x_admin_token, settings)
        management_token = None  # preserved by the storage layer

    token = f"tipme-verify-{secrets.token_urlsafe(8)}"
    record = storage.upsert(
        handle=handle,
        lightning_address=address,
        preferred_asset=request.preferred_asset,
        minimum_tip_minor=request.minimum_tip_minor_units,
        display_name=request.display_name,
        claim_token=token,
        management_token=management_token,
    )

    return RegisterResponse(
        platform=record.platform,
        username=record.username,
        lightning_address=record.lightning_address,
        verified=record.verified,
        claim_token=token,
        # Shown once, on first claim only. Re-issuing it on every update would
        # let anyone who can read one response take the record over.
        management_token=management_token,
        verification_instructions=(
            f"Add '{token}' to your {handle.platform} bio, then contact support to "
            "complete verification. Automated bio checks are not available: neither "
            "platform offers a third-party API for reading a profile, and scraping "
            "would breach their terms. See docs/PHASE2.md."
        ),
    )


@app.post("/v1/oauth/{platform}/start", response_model=OAuthStartResponse)
def oauth_start(
    platform: str,
    request: OAuthStartRequest,
    http_request: Request,
    settings: Settings = Depends(get_settings),
) -> OAuthStartResponse:
    """Begins platform sign-in for a handle a creator is claiming or already
    owns.

    Deliberately does not require the existing record's management token:
    the whole point of this endpoint is that a real sign-in with Instagram or
    TikTok is *stronger* proof of ownership than holding a bearer token, and
    is the direct fix for the handle-squatting gap the manual bio-code path
    always had — someone who registered `@realcreator` first, pointing tips
    at their own wallet, cannot also sign in as `@realcreator` on Instagram.
    Only the real account owner can complete the callback that follows this.
    """
    if platform != request.platform:
        raise HTTPException(status_code=400, detail="platform mismatch")
    config = oauth.config_for(platform)
    if config is None:
        raise HTTPException(
            status_code=503,
            detail=f"{platform} sign-in is not configured on this registry yet",
        )
    try:
        handle = normalise_handle(platform, request.username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    try:
        address = lightning.normalise(request.lightning_address)
    except lightning.InvalidLightningAddress as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    if request.preferred_asset not in ASSETS:
        raise HTTPException(
            status_code=400,
            detail=f"preferred_asset must be one of {', '.join(ASSETS)}",
        )

    _rate_limit_registration(_client_key(http_request), settings)

    state = secrets.token_urlsafe(24)
    _oauth_pending[state] = _PendingOAuth(
        platform=platform,
        handle=handle,
        lightning_address=address,
        preferred_asset=request.preferred_asset,
        minimum_tip_minor=request.minimum_tip_minor_units,
        display_name=request.display_name,
        created_at=time.monotonic(),
    )
    return OAuthStartResponse(
        authorize_url=oauth.build_authorize_url(config, state),
        expires_in=int(_OAUTH_STATE_TTL),
    )


@app.get("/v1/oauth/{platform}/callback")
async def oauth_callback(
    platform: str,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> RedirectResponse:
    """Where Instagram/TikTok send the user's browser after they consent (or
    decline). Never called by the app directly.

    Always ends in a redirect to the app's own URL scheme — there is nothing
    else this request could usefully return, since it is a full-page browser
    navigation happening inside the system auth session, not an API call the
    app is waiting on synchronously.
    """
    def finish(status: str, **extra: str) -> RedirectResponse:
        params = {"platform": platform, "status": status, **extra}
        return RedirectResponse(f"{settings.app_url_scheme}://oauth-complete?{urlencode(params)}")

    if error:
        return finish("error", reason=error)

    pending = _oauth_pending.pop(state, None) if state else None
    if pending is None or pending.platform != platform:
        return finish("error", reason="expired_or_invalid_state")
    if time.monotonic() - pending.created_at > _OAUTH_STATE_TTL:
        return finish("error", reason="expired")

    config = oauth.config_for(platform)
    if config is None or not code:
        return finish("error", reason="not_configured")

    try:
        username, platform_user_id = await oauth.exchange_code(config, code)
    except oauth.OAuthError:
        return finish("error", reason="sign_in_failed")

    if username.strip().lower() != pending.handle.username:
        return finish(
            "error",
            reason="account_mismatch",
            signed_in_as=username,
            expected=pending.handle.username,
        )

    is_new_claim = storage.get(pending.handle) is None
    management_token = (
        f"tipme-manage-{secrets.token_urlsafe(24)}" if is_new_claim else None
    )
    record = storage.upsert(
        handle=pending.handle,
        lightning_address=pending.lightning_address,
        preferred_asset=pending.preferred_asset,
        minimum_tip_minor=pending.minimum_tip_minor,
        display_name=pending.display_name,
        claim_token=f"tipme-verify-{secrets.token_urlsafe(8)}",
        management_token=management_token,
    )
    record = storage.set_verified(
        pending.handle, True, via="oauth", platform_user_id=platform_user_id,
    )

    session_id = secrets.token_urlsafe(24)
    _oauth_sessions[session_id] = _OAuthSession(
        handle=pending.handle,
        lightning_address=record.lightning_address,
        management_token=management_token or storage.management_token(pending.handle),
        claim_token=storage.claim_token(pending.handle),
        created_at=time.monotonic(),
    )
    return finish("success", username=username, session_id=session_id)


@app.get("/v1/oauth/session/{session_id}", response_model=OAuthSessionResponse)
def oauth_session(session_id: str) -> OAuthSessionResponse:
    """One-time collection point for what `/callback` produced.

    Burns the entry on read. The app calls this immediately after
    `ASWebAuthenticationSession` returns control to it, over a direct HTTPS
    request rather than trusting anything carried in the redirect URL itself.
    """
    session = _oauth_sessions.pop(session_id, None)
    if session is None or time.monotonic() - session.created_at > _OAUTH_SESSION_TTL:
        raise HTTPException(status_code=404, detail="session expired or already used")
    return OAuthSessionResponse(
        platform=session.handle.platform,
        username=session.handle.username,
        lightning_address=session.lightning_address,
        verified=True,
        claim_token=session.claim_token,
        management_token=session.management_token,
    )


@app.post("/v1/oauth/{platform}/identity/start", response_model=OAuthStartResponse)
def oauth_identity_start(platform: str, settings: Settings = Depends(get_settings)) -> OAuthStartResponse:
    """Begins sign-in for someone who only wants to say "this is me" — a
    sender pairing their own handle for a "sending as" badge, not a creator
    claiming a wallet. Nothing about a handle or a wallet is taken here; there
    is nothing to validate before starting, unlike `/oauth/{platform}/start`.
    """
    config = oauth.config_for(platform, purpose="identity")
    if config is None:
        raise HTTPException(
            status_code=503,
            detail=f"{platform} sign-in is not configured on this registry yet",
        )
    state = secrets.token_urlsafe(24)
    _identity_pending[state] = _PendingIdentity(platform=platform, created_at=time.monotonic())
    return OAuthStartResponse(
        authorize_url=oauth.build_authorize_url(config, state),
        expires_in=int(_OAUTH_STATE_TTL),
    )


@app.get("/v1/oauth/{platform}/identity/callback")
async def oauth_identity_callback(
    platform: str,
    code: str | None = None,
    state: str | None = None,
    error: str | None = None,
    settings: Settings = Depends(get_settings),
) -> RedirectResponse:
    """Where Instagram/TikTok redirect after an identity-only sign-in. Never
    writes to `storage` — this proves a username, nothing more."""
    if error:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason=error)

    pending = _identity_pending.pop(state, None) if state else None
    if pending is None or pending.platform != platform:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason="expired_or_invalid_state")
    if time.monotonic() - pending.created_at > _OAUTH_STATE_TTL:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason="expired")

    config = oauth.config_for(platform, purpose="identity")
    if config is None or not code:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason="not_configured")

    try:
        username, platform_user_id = await oauth.exchange_code(config, code)
    except oauth.OAuthError:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason="sign_in_failed")

    # Structured audit trail for every identity connect. This is the only
    # place any of it is recorded at all -- nothing is persisted server-side
    # (see SenderIdentityStore.swift), so this log line is the sole durable
    # record that a "sending as" badge was ever proven, by whom (the
    # platform's own account id, not just the handle it had that day), and
    # when. There is no matching disconnect event to log here: disconnecting
    # only clears local on-device storage and never calls the registry, so
    # the server genuinely has nothing to observe when it happens.
    logger.info(json.dumps({
        "event": "identity_connected", "platform": platform,
        "username": username, "platform_user_id": platform_user_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }))

    session_id = secrets.token_urlsafe(24)
    _identity_sessions[session_id] = _IdentitySession(
        platform=platform, username=username, created_at=time.monotonic(),
    )
    return _oauth_redirect(settings.app_url_scheme, platform, "success",
                           username=username, session_id=session_id)


@app.get("/v1/oauth/identity-session/{session_id}")
def oauth_identity_session(session_id: str) -> dict:
    """One-time collection point for an identity-only sign-in, mirroring
    `/v1/oauth/session/{id}` but with no wallet fields to leak."""
    session = _identity_sessions.pop(session_id, None)
    if session is None or time.monotonic() - session.created_at > _OAUTH_SESSION_TTL:
        raise HTTPException(status_code=404, detail="session expired or already used")
    return {"platform": session.platform, "username": session.username}


def _client_key(request: Request) -> str:
    """Best-effort client identity for rate limiting.

    Behind a proxy the socket address is the proxy's, so the forwarded header is
    used when present. That header is client-controlled and trivially spoofed —
    it is adequate for throttling casual abuse and is not a security control.
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _authorise_update(
    handle,
    storage: Storage,
    management_token: str | None,
    admin_token: str | None,
    settings: Settings,
    session_user_id: str | None = None,
) -> None:
    if settings.admin_token and admin_token and secrets.compare_digest(admin_token, settings.admin_token):
        return

    # A handle linked straight to a TipMe account (see /v1/me/creators) has
    # no management token at all -- the session that owns the linked
    # account is its only credential, checked here instead.
    record = storage.get(handle)
    if record is not None and record.tipme_user_id is not None:
        if session_user_id and session_user_id == record.tipme_user_id:
            return
        raise HTTPException(
            status_code=403,
            detail="This handle is linked to a different TipMe account. Log into that account to change it.",
        )

    stored = storage.management_token(handle)
    if stored is None:
        # A record predating management tokens cannot be updated anonymously;
        # failing closed is the only safe default for a payment destination.
        raise HTTPException(
            status_code=403,
            detail="This handle is already registered and cannot be changed here. Contact support.",
        )
    if not management_token or not secrets.compare_digest(management_token, stored):
        raise HTTPException(
            status_code=403,
            detail="This handle is already registered. Provide its management token to change it.",
        )


@app.put("/v1/creators/{platform}/{username}/photo", status_code=204)
async def upload_photo(
    platform: str,
    username: str,
    photo: UploadFile = File(...),
    x_management_token: str | None = Header(default=None),
    x_admin_token: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> Response:
    """Sets (or replaces) a creator's confirm-screen photo.

    Cosmetic only — the payment destination is the signed record, not this.
    Gated the same way changing the wallet is, so a stranger who does not hold
    the management token cannot deface a creator's confirm card.
    """
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    if storage.get(handle) is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    _authorise_update(handle, storage, x_management_token, x_admin_token, settings)

    media_types = {media: extension for extension, media in _PHOTO_EXTENSIONS}
    if photo.content_type not in media_types:
        raise HTTPException(status_code=400, detail="photo must be JPEG or PNG")

    body = await photo.read()
    if not body:
        raise HTTPException(status_code=400, detail="photo is empty")
    if len(body) > settings.max_photo_bytes:
        raise HTTPException(
            status_code=400,
            detail=f"photo must be {settings.max_photo_bytes // (1024 * 1024)}MB or smaller",
        )

    settings.photos_dir.mkdir(parents=True, exist_ok=True)
    # Clear whichever extension might already be stored, so switching from a
    # PNG to a JPEG (or back) doesn't leave a stale file being served
    # alongside the new one.
    for extension, _media_type in _PHOTO_EXTENSIONS:
        (settings.photos_dir / f"{handle.platform}_{handle.username}.{extension}").unlink(missing_ok=True)

    extension = media_types[photo.content_type]
    (settings.photos_dir / f"{handle.platform}_{handle.username}.{extension}").write_bytes(body)
    return Response(status_code=204)


@app.get("/v1/creators/{platform}/{username}/photo")
def get_photo(
    platform: str,
    username: str,
    settings: Settings = Depends(get_settings),
) -> FileResponse:
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    for extension, media_type in _PHOTO_EXTENSIONS:
        path = settings.photos_dir / f"{handle.platform}_{handle.username}.{extension}"
        if path.exists():
            return FileResponse(path, media_type=media_type,
                                headers={"Cache-Control": "public, max-age=3600"})
    raise HTTPException(status_code=404, detail="no photo set for this creator")


@app.delete("/v1/creators/{platform}/{username}", status_code=204)
def unregister(
    platform: str,
    username: str,
    authorization: str | None = Header(default=None),
    x_management_token: str | None = Header(default=None),
    x_admin_token: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> Response:
    """Unlinks a creator handle.

    Self-service: the same trust boundary as changing where tips go
    (`_authorise_update`) -- the device holding the management token issued
    at first claim can remove the record, same as it can update it, and the
    session for a TipMe-account-linked handle can remove that. Admin token
    still works too, for support requests from a device that lost its
    token.
    """
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    if storage.get(handle) is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    session_user_id = None
    if authorization and authorization.startswith("Bearer "):
        session_user_id = storage.session_user_id(authorization.removeprefix("Bearer ").strip())
    _authorise_update(handle, storage, x_management_token, x_admin_token, settings,
                      session_user_id=session_user_id)

    if not storage.delete(handle):
        raise HTTPException(status_code=404, detail="creator not registered")
    for extension, _media_type in _PHOTO_EXTENSIONS:
        (settings.photos_dir / f"{handle.platform}_{handle.username}.{extension}").unlink(missing_ok=True)
    return Response(status_code=204)


@app.post("/v1/creators/{platform}/{username}/verify")
def verify(
    platform: str,
    username: str,
    x_admin_token: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> dict:
    """Marks a handle verified.

    Admin-only and manual by necessity. Proving that the person registering
    ``@someone`` really is ``@someone`` requires either reading their profile
    bio (no third-party API exists for either platform, and scraping breaches
    both sets of terms) or platform OAuth (TikTok Login Kit and Instagram's
    Graph API, both of which need App Review). Until one of those is in place,
    a human checks the claim token and flips this flag.
    """
    _require_admin(x_admin_token, settings)
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    record = storage.set_verified(handle, True, via="admin")
    if record is None:
        raise HTTPException(status_code=404, detail="creator not registered")
    return {"platform": record.platform, "username": record.username, "verified": True}


def _require_admin(token: str | None, settings: Settings) -> None:
    if not settings.admin_token:
        raise HTTPException(status_code=503, detail="admin operations are not configured")
    # Constant-time comparison: a timing oracle on an admin token is a slow but
    # entirely practical way to take over the verification flag.
    if not token or not secrets.compare_digest(token, settings.admin_token):
        raise HTTPException(status_code=403, detail="invalid admin token")
