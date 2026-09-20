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
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, UploadFile, File
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel, Field

from . import accounts, bitcoin_chain, grid_rail, lightning, lightning_node, oauth, rates as rates_module, signing, turnkey_stamp
from .handles import Handle, InvalidHandle, normalise as normalise_handle
from .storage import Account, CreatorRecord, EmailTaken, InsufficientBalance, PendingDeposit, Storage

ASSETS = ("bitcoin", "usdt")

# Below this, a Lightning routing fee can easily exceed the amount itself.
# Not a security control -- just guards against a deposit/withdrawal nobody
# would actually want.
MIN_LIGHTNING_SATS = 100

# Same idea for on-chain: below this, a single input's own network fee can
# exceed the amount being withdrawn.
MIN_ONCHAIN_SATS = 1000

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

# Guards against paying the same withdrawal invoice twice -- a retried
# client request must not become two real Lightning payments. Same
# single-process caveat as the rate-limit windows above: a multi-process
# deployment needs this moved to shared storage.
_paid_lightning_invoices: set[str] = set()


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


def _optional_current_user(
    authorization: str | None = Header(default=None),
    storage: Storage = Depends(get_storage),
) -> str | None:
    """Same as `get_current_user`, but returns `None` instead of raising when
    there is no (or an invalid) bearer token.

    Creator registration must stay usable by someone who has never signed
    up for a TipMe account at all -- that's the whole "point at your
    existing Lightning wallet" path this registry has always supported. This
    exists only to *additionally* capture the caller's `user_id` when they
    happen to be signed in, so their handle can be linked to their account --
    see `register`.
    """
    if not authorization or not authorization.startswith("Bearer "):
        return None
    return storage.session_user_id(authorization.removeprefix("Bearer ").strip())


def get_lightning_rail() -> lightning_node.LightningRail:
    """Resolves fresh on every request, same convention as
    `oauth.config_for` -- so a test can monkeypatch
    `lightning_node.rail_from_env` without any app-level caching to reset,
    and so credentials added to the environment after the process started
    are picked up without a restart.
    """
    rail = lightning_node.rail_from_env()
    if rail is None:
        raise HTTPException(
            status_code=503,
            detail="Lightning deposits/withdrawals are not configured on this registry yet",
        )
    return rail


def get_onchain_rail() -> bitcoin_chain.OnChainRail:
    """Same fail-closed, resolve-fresh convention as `get_lightning_rail`."""
    rail = bitcoin_chain.rail_from_env()
    if rail is None:
        raise HTTPException(
            status_code=503,
            detail="On-chain Bitcoin deposits/withdrawals are not configured on this registry yet",
        )
    return rail


def get_grid_rail() -> grid_rail.GridRail:
    """Same fail-closed, resolve-fresh convention as `get_lightning_rail`."""
    rail = grid_rail.rail_from_env()
    if rail is None:
        raise HTTPException(
            status_code=503,
            detail="Grid transfers are not configured on this registry yet",
        )
    return rail


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


class BalanceEntry(BaseModel):
    asset: str
    balance_minor: int


class MeResponse(BaseModel):
    user_id: str
    email: str
    balances: list[BalanceEntry]


class DepositLightningRequest(BaseModel):
    amount_sats: int = Field(ge=MIN_LIGHTNING_SATS)


class DepositLightningResponse(BaseModel):
    payment_request: str
    payment_hash: str
    amount_sats: int


class DepositStatusResponse(BaseModel):
    status: str  # "pending" | "completed"
    balances: list[BalanceEntry]


class WithdrawLightningRequest(BaseModel):
    # A fixed-amount BOLT11 invoice only, for this first pass -- a
    # zero-amount invoice would need the client to state an amount
    # separately, which is a real case but not one this needs to handle to
    # get real testing started today.
    payment_request: str


class WithdrawLightningResponse(BaseModel):
    payment_hash: str
    amount_sats: int
    fee_sats: int
    balances: list[BalanceEntry]


class DepositBitcoinResponse(BaseModel):
    address: str


class WithdrawBitcoinRequest(BaseModel):
    to_address: str
    amount_sats: int = Field(ge=MIN_ONCHAIN_SATS)


class WithdrawBitcoinResponse(BaseModel):
    txid: str
    amount_sats: int
    fee_sats: int
    balances: list[BalanceEntry]


class TransferRequest(BaseModel):
    to_email: str
    asset: str
    amount_minor: int = Field(gt=0)


class TransferResponse(BaseModel):
    balances: list[BalanceEntry]


class SimulateTestPaymentRequest(BaseModel):
    payment_request: str


class TipToCreatorRequest(BaseModel):
    asset: str
    amount_minor: int = Field(gt=0)


class DepositApplePayRequest(BaseModel):
    amount_minor: int = Field(gt=0)
    # The client's own idempotency key -- a PKPayment transaction
    # identifier when a real Apple Pay sheet was shown, or any
    # caller-chosen unique string for the no-card dummy path. See
    # `deposit_apple_pay`.
    reference: str = Field(min_length=1)


class GridTransferRequest(BaseModel):
    to_email: str
    amount_minor: int = Field(gt=0)


class GridTransferResponse(BaseModel):
    transfer_id: str
    grid_transaction_id: str
    status: str


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
    return MeResponse(
        user_id=account.id,
        email=account.email,
        balances=_balance_entries(user_id, storage),
    )


def _balance_entries(user_id: str, storage: Storage) -> list[BalanceEntry]:
    balances = storage.get_balances(user_id)
    return [BalanceEntry(asset=asset, balance_minor=balances.get(asset, 0)) for asset in ASSETS]


@app.post("/v1/deposit/lightning", response_model=DepositLightningResponse)
async def deposit_lightning(
    request: DepositLightningRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: lightning_node.LightningRail = Depends(get_lightning_rail),
) -> DepositLightningResponse:
    """Issues a real Lightning invoice for the signed-in user to deposit
    sats into their TipMe balance.

    Nothing is credited yet — an invoice existing proves nothing has been
    paid. `/v1/deposit/lightning/{payment_hash}/check` is what credits the
    ledger, once the node reports the invoice settled.
    """
    try:
        invoice = await rail.create_invoice(request.amount_sats, memo=f"TipMe deposit {user_id}")
    except lightning_node.LightningNodeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error

    storage.create_pending_deposit(
        user_id=user_id, asset="bitcoin", method="lightning_invoice",
        external_reference=invoice.payment_hash, amount_minor=invoice.amount_sats,
    )
    return DepositLightningResponse(
        payment_request=invoice.payment_request,
        payment_hash=invoice.payment_hash,
        amount_sats=invoice.amount_sats,
    )


@app.post("/v1/deposit/lightning/{payment_hash}/check", response_model=DepositStatusResponse)
async def check_lightning_deposit(
    payment_hash: str,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: lightning_node.LightningRail = Depends(get_lightning_rail),
) -> DepositStatusResponse:
    """Polled by the app after it shows the invoice's QR code.

    Credits the ledger the first time the node reports the invoice settled;
    safe to call as many times as the client likes for the same payment —
    see `Storage.complete_deposit_if_pending`, which is what actually
    enforces the ledger is only ever credited once.
    """
    pending = storage.get_pending_deposit("lightning_invoice", payment_hash)
    if pending is None or pending.user_id != user_id:
        raise HTTPException(status_code=404, detail="no such deposit")

    if pending.status == "pending":
        try:
            status = await rail.invoice_status(payment_hash)
        except lightning_node.LightningNodeError as error:
            raise HTTPException(status_code=502, detail=str(error)) from error
        if status.settled:
            storage.complete_deposit_if_pending(
                "lightning_invoice", payment_hash, reason="lightning_deposit",
            )
            pending = storage.get_pending_deposit("lightning_invoice", payment_hash)

    return DepositStatusResponse(status=pending.status, balances=_balance_entries(user_id, storage))


@app.post("/v1/deposit/lightning/{payment_hash}/simulate-test-payment", status_code=204)
async def simulate_lightning_test_payment(
    payment_hash: str,
    request: SimulateTestPaymentRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: lightning_node.LightningRail = Depends(get_lightning_rail),
) -> Response:
    """Sandbox-only: makes a pending deposit's own invoice look paid,
    without needing a second real wallet to pay it. Exists to prove the
    deposit -> webhook -> credited-ledger loop end-to-end during
    development -- calling this against a real mainnet rail fails with a
    clear error rather than silently doing nothing, since only a rail
    actually backed by a sandbox/regtest node can honour it.
    """
    pending = storage.get_pending_deposit("lightning_invoice", payment_hash)
    if pending is None or pending.user_id != user_id:
        raise HTTPException(status_code=404, detail="no such deposit")
    if not hasattr(rail, "simulate_test_payment"):
        raise HTTPException(status_code=400, detail="this rail does not support simulated test payments")

    try:
        await rail.simulate_test_payment(request.payment_request, pending.amount_minor)
    except lightning_node.LightningNodeError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error
    return Response(status_code=204)


@app.post("/v1/withdraw/lightning", response_model=WithdrawLightningResponse)
async def withdraw_lightning(
    request: WithdrawLightningRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: lightning_node.LightningRail = Depends(get_lightning_rail),
) -> WithdrawLightningResponse:
    """Pays a real Lightning invoice out of the signed-in user's balance.

    The balance is debited *before* the payment is attempted, then refunded
    if the payment fails — never the other way around. Attempting the
    payment first and crediting afterwards would let two concurrent
    withdrawal requests both pass a balance check against the same starting
    balance and overdraw the account; debiting first makes the second one
    fail with `InsufficientBalance` immediately, the same guarantee
    `adjust_balance` already gives tip-sending.
    """
    if request.payment_request in _paid_lightning_invoices:
        raise HTTPException(status_code=409, detail="this invoice has already been paid")

    try:
        decoded = await rail.decode_invoice(request.payment_request)
    except lightning_node.LightningNodeError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    if decoded.amount_sats < MIN_LIGHTNING_SATS:
        raise HTTPException(
            status_code=400,
            detail=f"invoice must be for at least {MIN_LIGHTNING_SATS} sats",
        )

    try:
        storage.adjust_balance(user_id, "bitcoin", -decoded.amount_sats, reason="lightning_withdrawal")
    except InsufficientBalance as error:
        raise HTTPException(status_code=402, detail=str(error)) from error

    try:
        result = await rail.pay_invoice(request.payment_request)
    except lightning_node.LightningNodeError as error:
        storage.adjust_balance(user_id, "bitcoin", decoded.amount_sats,
                               reason="lightning_withdrawal_failed_refund")
        raise HTTPException(status_code=502, detail=str(error)) from error

    _paid_lightning_invoices.add(request.payment_request)
    return WithdrawLightningResponse(
        payment_hash=result.payment_hash,
        amount_sats=decoded.amount_sats,
        fee_sats=result.fee_sats,
        balances=_balance_entries(user_id, storage),
    )


async def _ensure_grid_customer(
    storage: Storage, rail: grid_rail.GridRail, user_id: str,
) -> tuple[str, str]:
    """Returns `(grid_customer_id, grid_account_id)` for a TipMe user,
    provisioning them on Grid the first time they're party to a transfer.
    See `grid_rail`'s module docstring for why every user needs their own
    Grid customer, unlike the single shared node Voltage/classic Lightspark
    used.
    """
    existing = storage.get_grid_customer(user_id)
    if existing is not None:
        return existing.grid_customer_id, existing.grid_account_id

    account = storage.get_user(user_id)
    if account is None:
        raise HTTPException(status_code=401, detail="invalid or expired session")
    try:
        handle = await rail.ensure_customer(user_id, account.email)
    except grid_rail.GridError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error
    record = storage.record_grid_customer(
        user_id=user_id, grid_customer_id=handle.customer_id,
        grid_account_id=handle.account_id, currency=rail.currency,
    )
    return record.grid_customer_id, record.grid_account_id


async def _ensure_wallet_session(
    storage: Storage, rail: grid_rail.GridRail, account_id: str,
) -> grid_rail.WalletSession:
    """Returns a verified `WalletSession` for a Grid Embedded Wallet
    account, reusing a cached one from `storage` if it hasn't expired yet,
    and verifying a fresh one (persisting it) otherwise. See
    `grid_rail.GridRail.create_wallet_session` for what "verifying" means
    here -- an HPKE-sealed OTP round trip, not just an API call.
    """
    cached = storage.get_grid_wallet_session(account_id)
    if cached is not None and cached.expires_at > datetime.now(timezone.utc):
        keypair = turnkey_stamp.TurnkeyKeyPair(
            private_key_hex=cached.session_private_key, public_key_hex=cached.session_public_key,
        )
        return grid_rail.WalletSession(
            account_id=account_id, keypair=keypair, expires_at=cached.expires_at.isoformat(),
        )

    try:
        session = await rail.create_wallet_session(account_id)
    except grid_rail.GridError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error
    storage.record_grid_wallet_session(
        account_id=account_id, session_private_key=session.keypair.private_key_hex,
        session_public_key=session.keypair.public_key_hex,
        expires_at=datetime.fromisoformat(session.expires_at),
    )
    return session


@app.post("/v1/transfer/grid", response_model=GridTransferResponse)
async def transfer_via_grid(
    request: GridTransferRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: grid_rail.GridRail = Depends(get_grid_rail),
) -> GridTransferResponse:
    """Moves real money between two TipMe users' Grid-backed accounts --
    the first proof that TipMe can settle a payment through an external
    rail rather than only ever updating its own ledger (see `/v1/transfer`
    for the ledger-only case). Sandbox-only for now: the sender's Grid
    account is funded on demand via Grid's sandbox harness rather than
    requiring a real funding source, exactly like `simulate_test_payment`
    did for the classic Lightning rail.
    """
    try:
        email = accounts.normalise_email(request.to_email)
    except accounts.InvalidEmail as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    found = storage.get_user_by_email(email)
    if found is None:
        raise HTTPException(status_code=404, detail="no TipMe account with that email")
    recipient, _password_hash = found
    if recipient.id == user_id:
        raise HTTPException(status_code=400, detail="cannot transfer to yourself")

    _sender_customer_id, sender_account_id = await _ensure_grid_customer(storage, rail, user_id)
    _recipient_customer_id, recipient_account_id = await _ensure_grid_customer(
        storage, rail, recipient.id,
    )

    try:
        await rail.fund_sandbox(sender_account_id, request.amount_minor)
        session = await _ensure_wallet_session(storage, rail, sender_account_id)
        result = await rail.transfer(
            sender_account_id, recipient_account_id, request.amount_minor, session,
        )
    except grid_rail.GridError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error

    record = storage.record_grid_transfer(
        from_user_id=user_id, to_user_id=recipient.id, grid_quote_id=result.quote_id,
        grid_transaction_id=result.transaction_id, currency=rail.currency,
        amount_minor=request.amount_minor, status=result.status,
    )
    return GridTransferResponse(
        transfer_id=record.id, grid_transaction_id=record.grid_transaction_id,
        status=record.status,
    )


@app.post("/v1/transfer/grid/{transaction_id}/check", response_model=GridTransferResponse)
async def check_grid_transfer(
    transaction_id: str,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: grid_rail.GridRail = Depends(get_grid_rail),
) -> GridTransferResponse:
    record = storage.get_grid_transfer(transaction_id)
    if record is None or user_id not in (record.from_user_id, record.to_user_id):
        raise HTTPException(status_code=404, detail="no such transfer")

    try:
        status = await rail.get_transaction_status(transaction_id)
    except grid_rail.GridError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error

    record = storage.update_grid_transfer_status(transaction_id, status) or record
    return GridTransferResponse(
        transfer_id=record.id, grid_transaction_id=record.grid_transaction_id,
        status=record.status,
    )


@app.post("/v1/webhooks/grid", status_code=204)
async def grid_webhook(
    request: Request,
    x_grid_signature: str = Header(alias="X-Grid-Signature"),
    storage: Storage = Depends(get_storage),
) -> Response:
    """Grid POSTs here whenever a transaction reaches a terminal state.
    Verifying the signature is what makes this trustworthy -- without it,
    anyone who found this URL could claim any transfer had completed
    without it ever having happened.
    """
    rail = grid_rail.rail_from_env()
    if rail is None:
        raise HTTPException(status_code=503, detail="Grid is not configured on this registry")

    body = await request.body()
    try:
        event = rail.verify_webhook(body, x_grid_signature)
    except grid_rail.GridError as error:
        raise HTTPException(status_code=401, detail=str(error)) from error

    transaction_id = event.get("transactionId")
    status = event.get("status")
    if not transaction_id or not status:
        return Response(status_code=204)

    storage.update_grid_transfer_status(transaction_id, status)
    return Response(status_code=204)


@app.post("/v1/deposit/bitcoin", response_model=DepositBitcoinResponse)
async def deposit_bitcoin(
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: bitcoin_chain.OnChainRail = Depends(get_onchain_rail),
) -> DepositBitcoinResponse:
    """Issues a fresh on-chain address for the signed-in user to deposit
    sats into their TipMe balance.

    Unlike a Lightning invoice, an on-chain address has no fixed amount --
    the ledger is credited with whatever confirmed amount later shows up at
    it, once `/v1/deposit/bitcoin/{address}/check` reports it.
    """
    index = storage.next_bitcoin_index()
    try:
        address = await rail.deposit_address(index)
    except bitcoin_chain.OnChainError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error

    storage.create_pending_deposit(
        user_id=user_id, asset="bitcoin", method="bitcoin_address",
        external_reference=address, amount_minor=0,
    )
    return DepositBitcoinResponse(address=address)


@app.post("/v1/deposit/bitcoin/{address}/check", response_model=DepositStatusResponse)
async def check_bitcoin_deposit(
    address: str,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: bitcoin_chain.OnChainRail = Depends(get_onchain_rail),
) -> DepositStatusResponse:
    """Polled by the app after it shows the address's QR code.

    Credits the ledger with whatever confirmed amount has arrived, the
    first time any has -- see `Storage.complete_deposit_with_amount`, which
    is what actually enforces the ledger is only ever credited once per
    address.
    """
    pending = storage.get_pending_deposit("bitcoin_address", address)
    if pending is None or pending.user_id != user_id:
        raise HTTPException(status_code=404, detail="no such deposit")

    if pending.status == "pending":
        try:
            received_sats = await rail.confirmed_received_sats(address)
        except bitcoin_chain.OnChainError as error:
            raise HTTPException(status_code=502, detail=str(error)) from error
        if received_sats > 0:
            storage.complete_deposit_with_amount(
                "bitcoin_address", address, received_sats, reason="bitcoin_deposit",
            )
            pending = storage.get_pending_deposit("bitcoin_address", address)

    return DepositStatusResponse(status=pending.status, balances=_balance_entries(user_id, storage))


@app.post("/v1/withdraw/bitcoin", response_model=WithdrawBitcoinResponse)
async def withdraw_bitcoin(
    request: WithdrawBitcoinRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
    rail: bitcoin_chain.OnChainRail = Depends(get_onchain_rail),
) -> WithdrawBitcoinResponse:
    """Sends a real on-chain transaction out of the signed-in user's
    balance.

    The balance is debited *before* the send is attempted, then refunded if
    it fails -- same reasoning as `withdraw_lightning`. The network fee is
    the operator's own cost, not charged against the user's balance -- this
    wallet has no notion yet of splitting it out.

    Known simplification: two withdrawals racing each other could both
    select the same UTXO and one broadcast would fail (refunded, same as
    any other on-chain error) rather than being queued behind the other --
    acceptable for a single-operator wallet, not for concurrent real usage.
    """
    try:
        storage.adjust_balance(user_id, "bitcoin", -request.amount_sats, reason="bitcoin_withdrawal")
    except InsufficientBalance as error:
        raise HTTPException(status_code=402, detail=str(error)) from error

    try:
        known_index_count = storage.bitcoin_index_count()
        change_index = storage.next_bitcoin_index()
        result = await rail.send(request.to_address, request.amount_sats,
                                 known_index_count, change_index)
    except bitcoin_chain.OnChainError as error:
        storage.adjust_balance(user_id, "bitcoin", request.amount_sats,
                               reason="bitcoin_withdrawal_failed_refund")
        raise HTTPException(status_code=502, detail=str(error)) from error

    return WithdrawBitcoinResponse(
        txid=result.txid,
        amount_sats=request.amount_sats,
        fee_sats=result.fee_sats,
        balances=_balance_entries(user_id, storage),
    )


@app.post("/v1/deposit/apple_pay", response_model=DepositStatusResponse)
async def deposit_apple_pay(
    request: DepositApplePayRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> DepositStatusResponse:
    """Credits the signed-in user's USDT balance for an Apple Pay top-up.

    This is a dummy funding source, not a real one: there is no payment
    processor (Stripe or similar) wired in yet to actually charge a card or
    verify an Apple Pay payment token, so this trusts the client-reported
    amount and credits it immediately -- no separate "check" step, unlike
    the Lightning/on-chain deposits above, because there is no external
    settlement to wait on. Same trust level as `simulate_lightning_test_payment`
    and Grid's `fund_sandbox`, just for a rail that has no real backing at
    all yet rather than a sandboxed real one; replacing this with a real
    charge is future work, not something this endpoint's callers need to
    know about when that happens -- the request/response shape does not
    have to change.

    `reference` is the caller's own idempotency key (a PKPayment
    transaction identifier from a real Apple Pay sheet, or any unique
    string for the no-card test path) so a retried request after a lost
    response does not double-credit -- same pattern `complete_deposit_if_
    pending` already gives the Lightning and on-chain rails.
    """
    existing = storage.get_pending_deposit("apple_pay", request.reference)
    if existing is not None and existing.user_id != user_id:
        raise HTTPException(status_code=404, detail="no such deposit")
    if existing is None:
        existing = storage.create_pending_deposit(
            user_id=user_id, asset="usdt", method="apple_pay",
            external_reference=request.reference, amount_minor=request.amount_minor,
        )
    if existing.status == "pending":
        storage.complete_deposit_if_pending("apple_pay", request.reference, reason="apple_pay_deposit")

    return DepositStatusResponse(status="completed", balances=_balance_entries(user_id, storage))


@app.post("/v1/transfer", response_model=TransferResponse)
def transfer(
    request: TransferRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> TransferResponse:
    """Moves money directly between two TipMe accounts' ledgers.

    No Lightning, no on-chain, no network call at all -- when both sender
    and recipient already hold custodial TipMe balances, sending between
    them is just two numbers changing together. This is the "internal
    transfer" case; sending to someone without a TipMe account still goes
    through the real Lightning/on-chain endpoints instead.
    """
    if request.asset not in ASSETS:
        raise HTTPException(status_code=400, detail=f"asset must be one of {ASSETS}")

    try:
        email = accounts.normalise_email(request.to_email)
    except accounts.InvalidEmail as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    found = storage.get_user_by_email(email)
    if found is None:
        raise HTTPException(status_code=404, detail="no TipMe account with that email")
    recipient, _password_hash = found
    if recipient.id == user_id:
        raise HTTPException(status_code=400, detail="cannot transfer to yourself")

    try:
        storage.transfer_balance(user_id, recipient.id, request.asset, request.amount_minor)
    except InsufficientBalance as error:
        raise HTTPException(status_code=402, detail=str(error)) from error

    return TransferResponse(balances=_balance_entries(user_id, storage))


@app.post("/v1/tip/{platform}/{username}", response_model=TransferResponse)
def tip_creator(
    platform: str,
    username: str,
    request: TipToCreatorRequest,
    user_id: str = Depends(get_current_user),
    storage: Storage = Depends(get_storage),
) -> TransferResponse:
    """Tips a creator directly out of the signed-in user's ledger balance --
    the core "person on my screen -> pay them" loop, for the one case that
    doesn't need Lightning, Grid, or any external rail at all: the creator
    already has a TipMe account linked to their handle (see `register`'s
    `tipme_user_id`).

    This is deliberately the *only* thing this endpoint does. A handle with
    no linked account returns 404 -- the client already has a fallback for
    that (the manual-Lightning-address path `TipFlow` offers when a creator
    "hasn't set up TipMe yet"), and this endpoint is not the place to grow a
    second one. No conversion either: same-asset only, same as `/v1/transfer`.
    """
    try:
        handle = normalise_handle(platform, username)
    except InvalidHandle as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    if request.asset not in ASSETS:
        raise HTTPException(status_code=400, detail=f"asset must be one of {ASSETS}")

    record = storage.get(handle)
    if record is None or record.tipme_user_id is None:
        raise HTTPException(
            status_code=404,
            detail=f"@{username} on {platform} has no linked TipMe account",
        )
    if record.tipme_user_id == user_id:
        raise HTTPException(status_code=400, detail="cannot tip yourself")

    try:
        storage.transfer_balance(user_id, record.tipme_user_id, request.asset, request.amount_minor)
    except InsufficientBalance as error:
        raise HTTPException(status_code=402, detail=str(error)) from error

    return TransferResponse(balances=_balance_entries(user_id, storage))


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
        "preferred_asset": record.preferred_asset,
        "minimum_tip_minor_units": record.minimum_tip_minor,
        "display_name": record.display_name,
        "verified": record.verified,
        # Whether this handle is linked to a signed-in TipMe account -- lets
        # the client route the actual payment ledger-to-ledger (see
        # `POST /v1/tip/{platform}/{username}`) instead of over Lightning.
        # The `tipme_user_id` itself is never exposed: nothing the client
        # does needs it, and a public creator lookup is not the place to
        # leak an internal account id.
        "tipme_linked": record.tipme_user_id is not None,
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
    tipme_user_id: str | None = Depends(_optional_current_user),
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

    Registering while signed in to a TipMe account additionally links the
    handle to that account (`tipme_user_id`) -- this is what lets a tip to
    this handle move ledger-to-ledger instead of over Lightning. See
    `POST /v1/tip/{platform}/{username}`.
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
        tipme_user_id=tipme_user_id,
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
    config = oauth.config_for(platform)
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

    config = oauth.config_for(platform)
    if config is None or not code:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason="not_configured")

    try:
        username, _platform_user_id = await oauth.exchange_code(config, code)
    except oauth.OAuthError:
        return _oauth_redirect(settings.app_url_scheme, platform, "error", reason="sign_in_failed")

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
) -> None:
    if settings.admin_token and admin_token and secrets.compare_digest(admin_token, settings.admin_token):
        return

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
