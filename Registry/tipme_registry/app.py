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

import os
import secrets
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException, Response
from pydantic import BaseModel, Field

from . import lightning, signing
from .handles import InvalidHandle, normalise as normalise_handle
from .storage import CreatorRecord, Storage

ASSETS = ("bitcoin", "usdt")


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


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


_settings: Settings | None = None
_storage: Storage | None = None


def get_storage(settings: Settings = Depends(get_settings)) -> Storage:
    global _storage
    if _storage is None:
        _storage = Storage(settings.database_path)
    return _storage


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
        "preferred_asset": record.preferred_asset,
        "minimum_tip_minor_units": record.minimum_tip_minor,
        "display_name": record.display_name,
        "verified": record.verified,
        "updated_at": signing.iso8601(record.updated_at),
        # Signed-at is what makes a captured response un-replayable after a
        # creator has moved wallet; the client rejects anything too old.
        "signed_at": signing.iso8601(now),
    }
    return signing.sign_payload(settings.private_key, payload)


@app.post("/v1/creators", response_model=RegisterResponse, status_code=201)
def register(
    request: RegisterRequest,
    storage: Storage = Depends(get_storage),
) -> RegisterResponse:
    """Creator onboarding: link a handle to a wallet.

    Registration is open, verification is not. Anyone may claim any handle, so
    a fresh record is always unverified and the app labels it as such. Without
    that distinction, registering ``@charlidamelio`` would be enough to collect
    her tips.
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

    token = f"tipme-verify-{secrets.token_urlsafe(8)}"
    record = storage.upsert(
        handle=handle,
        lightning_address=address,
        preferred_asset=request.preferred_asset,
        minimum_tip_minor=request.minimum_tip_minor_units,
        display_name=request.display_name,
        claim_token=token,
    )

    return RegisterResponse(
        platform=record.platform,
        username=record.username,
        lightning_address=record.lightning_address,
        verified=record.verified,
        claim_token=token,
        verification_instructions=(
            f"Add '{token}' to your {handle.platform} bio, then contact support to "
            "complete verification. Automated bio checks are not available: neither "
            "platform offers a third-party API for reading a profile, and scraping "
            "would breach their terms. See docs/PHASE2.md."
        ),
    )


@app.delete("/v1/creators/{platform}/{username}", status_code=204)
def unregister(
    platform: str,
    username: str,
    x_admin_token: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
    storage: Storage = Depends(get_storage),
) -> Response:
    _require_admin(x_admin_token, settings)
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    if not storage.delete(handle):
        raise HTTPException(status_code=404, detail="creator not registered")
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

    record = storage.set_verified(handle, True)
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
