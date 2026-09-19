"""Real money movement via Lightspark's Grid API.

## Why this replaces `lightspark_rail.py`

The first attempt at a Lightspark integration was built against Lightspark's
*other* product: a node-backed, invoice-based Lightning API reached over
GraphQL. That is not what a Grid account is provisioned for. Grid
(`https://api.lightspark.com/grid/{version}`, a dated REST API) is an
accounts/KYC payments platform -- Customers, internal and external bank
accounts, Quotes, Transactions -- built for cross-border payouts and
on/off-ramps, not a shared Lightning node you send BOLT11 invoices through.
There is no drop-in replacement for `LightningRail` here: Grid has no
concept of "pay this invoice," only "move money from one account to
another," so this module implements its own, smaller protocol instead.

## The model

Grid is not one shared node the way a Voltage or classic-Lightspark
integration is -- it is a platform for *your customers*. Moving money
between two TipMe users means each of them has their own Grid `Customer`
record. Each customer is also auto-provisioned an `INTERNAL_FIAT` (bank
rail) account, but Grid rejects an account-to-account quote between two
different customers' `INTERNAL_FIAT` accounts outright -- confirmed live,
not from docs: "Internal account transfers are only allowed between
accounts owned by the same customer, between matching Spark-token embedded
wallets, or between the platform and one of its members' embedded wallets
when enabled." So this targets each customer's `EMBEDDED_WALLET` (Spark)
account instead -- which happens to be exactly the "move it across with a
Spark" mechanism this was always meant to prove, not a workaround bolted on
after the fact. `ensure_customer` provisions the customer lazily, the first
time a TipMe user is party to a Grid transfer, using obviously-synthetic
placeholder profile data (name/DOB/nationality) rather than real KYC
collection -- TipMe's signup flow only asks for an email and a password
today, and collecting real identity data is explicitly out of scope for
proving this rail works end to end. `Storage.grid_customers` remembers the
mapping afterwards so a user is only ever provisioned once.

TipMe's own bitcoin/usdt ledger (`ledger_balances`) is untouched by any of
this -- it is a separate custodial ledger for a separate purpose. This
module exists to prove a *different* rail works: real money moving through
Grid between two Grid-backed accounts, tracked in its own `grid_transfers`
table. Wiring the two together (e.g. an Apple Pay-funded balance that
settles through Grid) is future work.

## Sandbox-only capability

`fund_sandbox` calls `POST /sandbox/internal-accounts/{id}/fund`, which only
works against sandbox platform credentials -- it manufactures a settled
deposit into an internal account without a real bank transfer, so the first
end-to-end proof of this rail does not need a real funding source. Like
`simulate_test_payment` on the old node-backed module, this is not part of
transferring money in general -- no real rail can satisfy it.

## Wallet sessions -- why `transfer` needs more than an API call

An `EMBEDDED_WALLET` account is self-custodial: Grid will not execute a
quote sourced from one on Basic Auth alone, confirmed live -- "immediately
Execute is not supported for embedded-wallet source quotes. Create the
quote, then execute it via `POST /quotes/{id}/execute` with the
`Grid-Wallet-Signature` header." That header is a Turnkey API-key stamp
(Grid's embedded-wallet infrastructure is built on Turnkey), which needs a
verified session on the account, which needs an HPKE-sealed OTP round trip
-- see `turnkey_stamp.py`'s module docstring for the whole chain and why
it is hand-ported rather than borrowed from an SDK. `create_wallet_session`
does that round trip once per account (using the sandbox's fixed OTP,
since the account's email is a synthetic placeholder anyway); the
resulting `WalletSession.keypair` *is* the session signing key from then
on, and `transfer` uses it to build the `Grid-Wallet-Signature` for the
execute call. `app.py`'s `_ensure_wallet_session` caches the result in
`Storage.grid_wallet_sessions` against `WalletSession.expires_at`, the
same lazy-provision-once pattern `ensure_customer`/`grid_customers` uses.

## Webhooks

Grid signs webhook payloads with an asymmetric Secp256r1 (P-256) signature
in the `X-Grid-Signature` header, verified against a public key Grid gives
you during integration -- not the HMAC scheme the classic SDK used.
`verify_webhook` implements that verification directly since there is no
Grid Python SDK to lean on.

## Configuration

Reads ``REGISTRY_GRID_CLIENT_ID`` and ``REGISTRY_GRID_CLIENT_SECRET`` (an
API token from the Grid dashboard's Developers page -- HTTP Basic auth,
`<token id>:<client secret>`). ``REGISTRY_GRID_WEBHOOK_PUBLIC_KEY`` (PEM) is
required for `verify_webhook` but not for transfers themselves.
``REGISTRY_GRID_BASE_URL`` and ``REGISTRY_GRID_CURRENCY`` are optional,
defaulting to Grid's production host (sandbox vs. production is a property
of the API token itself, not the URL) and ``USDB`` -- the Spark/embedded-
wallet stablecoin, the only account type a cross-customer transfer can
move through. Until the first two are
set, ``rail_from_env`` returns ``None`` and the transfer endpoint fails
closed with a 503, the same convention every other rail in this codebase
uses.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
from dataclasses import dataclass

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from . import turnkey_stamp

DEFAULT_BASE_URL = "https://api.lightspark.com/grid/2025-10-13"
DEFAULT_CURRENCY = "USDB"


class GridError(Exception):
    """Raised for any Grid API failure: a non-2xx response, a malformed
    reply, or a webhook that doesn't verify."""


@dataclass(frozen=True)
class GridConfig:
    client_id: str
    client_secret: str
    webhook_public_key_pem: str | None
    base_url: str
    currency: str


def config_from_env() -> GridConfig | None:
    client_id = os.environ.get("REGISTRY_GRID_CLIENT_ID")
    client_secret = os.environ.get("REGISTRY_GRID_CLIENT_SECRET")
    if not (client_id and client_secret):
        return None
    return GridConfig(
        client_id=client_id, client_secret=client_secret,
        webhook_public_key_pem=os.environ.get("REGISTRY_GRID_WEBHOOK_PUBLIC_KEY"),
        base_url=os.environ.get("REGISTRY_GRID_BASE_URL", DEFAULT_BASE_URL),
        currency=os.environ.get("REGISTRY_GRID_CURRENCY", DEFAULT_CURRENCY),
    )


@dataclass(frozen=True)
class GridCustomerHandle:
    customer_id: str
    account_id: str


@dataclass(frozen=True)
class GridTransferResult:
    quote_id: str
    transaction_id: str
    status: str


@dataclass(frozen=True)
class WalletSession:
    """A verified session on one Embedded Wallet account: `keypair` is the
    TEK keypair generated for the login that verified it, which -- in
    Grid's client-held-key model -- *becomes* the long-lived session
    signing key, valid until `expires_at`. See `turnkey_stamp`'s module
    docstring for what this is proving and why."""
    account_id: str
    keypair: turnkey_stamp.TurnkeyKeyPair
    expires_at: str


class GridRail:
    """Talks to Grid's REST API directly over `httpx` -- there is no
    official Grid Python SDK to wrap, unlike the classic Lightning API.

    `client` is injectable so tests can pass a fake transport, the same
    seam every other rail in this codebase uses to avoid touching a real
    network.
    """

    def __init__(self, config: GridConfig, client: httpx.AsyncClient | None = None):
        self._config = config
        self._client = client or httpx.AsyncClient(
            base_url=config.base_url,
            auth=(config.client_id, config.client_secret),
            timeout=30.0,
        )

    @property
    def currency(self) -> str:
        return self._config.currency

    async def _request(self, method: str, path: str, **kwargs) -> dict:
        try:
            response = await self._client.request(method, path, **kwargs)
        except httpx.HTTPError as error:
            raise GridError(f"Grid request failed: {error}") from error
        if response.status_code >= 400:
            raise GridError(
                f"Grid {method} {path} returned {response.status_code}: {response.text}"
            )
        if not response.content:
            return {}
        return response.json()

    async def ensure_customer(self, platform_user_id: str, email: str) -> GridCustomerHandle:
        """Finds or creates the Grid customer for a TipMe user, and their
        currency-matching internal account, by `platform_user_id` (TipMe's
        own user id, stored on Grid as `platformCustomerId`). Safe to call
        every time a user is party to a transfer -- looks up the existing
        customer rather than creating a duplicate.
        """
        existing = await self._request(
            "GET", "/customers", params={"platformCustomerId": platform_user_id},
        )
        customers = existing.get("data", [])
        if customers:
            customer_id = customers[0]["id"]
        else:
            created = await self._request(
                "POST", "/customers",
                json={
                    "customerType": "INDIVIDUAL",
                    "platformCustomerId": platform_user_id,
                    "region": "US",
                    # Not the currency transfers actually move through --
                    # see below -- just a customer-level preference Grid
                    # asks for at creation time.
                    "currencies": ["USD"],
                    # Sandbox-only placeholder identity data: TipMe's signup
                    # flow collects only an email and a password today, and
                    # real KYC collection is explicitly out of scope for
                    # proving this rail works -- see the module docstring.
                    # Grid requires a first and last name, so a bare email
                    # local-part (which may have no space at all) won't do.
                    "fullName": f"TipMe User {platform_user_id[:8]}",
                    "birthDate": "1990-01-01",
                    "nationality": "US",
                    "email": email,
                },
            )
            customer_id = created["id"]

        # A brand-new customer's EMBEDDED_WALLET (Spark) account is
        # provisioned asynchronously, moments after creation -- an existing
        # customer's is already long since ready, but a customer created
        # just above by this same call can briefly come back empty. Retry a
        # few times rather than failing a transfer over a race that
        # resolves itself within a second or two.
        for attempt in range(5):
            accounts = await self._request(
                "GET", "/customers/internal-accounts", params={"customerId": customer_id},
            )
            for account in accounts.get("data", []):
                currency = account.get("totalBalance", {}).get("currency", {}).get("code")
                if account.get("type") == "EMBEDDED_WALLET" and currency == self._config.currency:
                    return GridCustomerHandle(customer_id=customer_id, account_id=account["id"])
            if attempt < 4:
                await asyncio.sleep(0.5)
        raise GridError(
            f"customer {customer_id} has no EMBEDDED_WALLET account in {self._config.currency} yet"
        )

    async def fund_sandbox(self, account_id: str, amount_minor: int) -> None:
        """Sandbox-only: manufactures a settled deposit into an internal
        account. Raises `GridError` (most likely because these are
        production credentials) rather than silently doing nothing."""
        await self._request(
            "POST", f"/sandbox/internal-accounts/{account_id}/fund",
            json={"amount": amount_minor},
        )

    async def _poll_until_ready(self, method: str, path: str, **kwargs) -> dict:
        """Grid can answer a signed-wallet-flow call with `{"status":
        "PROCESSING"}` while the underlying wallet-provider activity is
        still in flight, and documents the client re-sending the
        byte-identical request until it clears -- see e.g. `POST /auth/
        credentials/{id}/verify`'s and `/challenge`'s response docs.
        """
        for attempt in range(5):
            response = await self._request(method, path, **kwargs)
            if response.get("status") != "PROCESSING":
                return response
            if attempt < 4:
                await asyncio.sleep(0.5)
        raise GridError(f"{method} {path} did not leave PROCESSING in time")

    async def create_wallet_session(self, account_id: str) -> WalletSession:
        """Verifies the Embedded Wallet account's auto-created `EMAIL_OTP`
        credential and returns the resulting session. See `turnkey_stamp`'s
        module docstring for what this proves and why Grid requires it at
        all: releasing a transfer sourced from an `EMBEDDED_WALLET` account
        needs a `Grid-Wallet-Signature` from a verified credential's
        session key, and a freshly created account has no verified session
        yet.

        Uses the sandbox's fixed magic OTP (`turnkey_stamp.sandbox_otp_code`)
        rather than an interactive code -- this account's email is a
        synthetic placeholder anyway (see `ensure_customer`), so there is
        no real inbox to read a real OTP from.
        """
        # The account's auto-created EMAIL_OTP credential can briefly lag
        # the account itself becoming visible -- confirmed live: querying
        # immediately after a brand-new account can see zero credentials
        # for a moment. Same race, same retry shape as `ensure_customer`'s
        # account-provisioning wait.
        email_otp_id = None
        for attempt in range(5):
            credentials = await self._request(
                "GET", "/auth/credentials", params={"accountId": account_id},
            )
            email_otp_id = next(
                (c["id"] for c in credentials.get("data", []) if c.get("type") == "EMAIL_OTP"), None,
            )
            if email_otp_id is not None:
                break
            if attempt < 4:
                await asyncio.sleep(0.5)
        if email_otp_id is None:
            raise GridError(f"account {account_id} has no EMAIL_OTP credential")

        challenge = await self._poll_until_ready(
            "POST", f"/auth/credentials/{email_otp_id}/challenge", json={},
        )
        target_bundle = challenge.get("otpEncryptionTargetBundle")
        if not target_bundle:
            raise GridError(f"challenge response has no otpEncryptionTargetBundle: {challenge}")

        tek_keypair = turnkey_stamp.generate_keypair()
        try:
            sealed = turnkey_stamp.seal_otp_bundle(
                turnkey_stamp.sandbox_otp_code(), tek_keypair.public_key_hex, target_bundle,
            )
        except turnkey_stamp.TurnkeyStampError as error:
            raise GridError(f"could not seal OTP bundle: {error}") from error
        verify_body = {"type": "EMAIL_OTP", "encryptedOtpBundle": json.dumps(sealed)}

        first_leg = await self._poll_until_ready(
            "POST", f"/auth/credentials/{email_otp_id}/verify", json=verify_body,
        )
        payload_to_sign = first_leg.get("payloadToSign")
        request_id = first_leg.get("requestId")
        if not payload_to_sign or not request_id:
            raise GridError(f"unexpected OTP verification challenge: {first_leg}")

        signature = turnkey_stamp.build_stamp(payload_to_sign, tek_keypair)
        session = await self._poll_until_ready(
            "POST", f"/auth/credentials/{email_otp_id}/verify", json=verify_body,
            headers={"Grid-Wallet-Signature": signature, "Request-Id": request_id},
        )
        expires_at = session.get("expiresAt")
        if not expires_at:
            raise GridError(f"unexpected auth session response: {session}")
        return WalletSession(account_id=account_id, keypair=tek_keypair, expires_at=expires_at)

    async def transfer(
        self, source_account_id: str, destination_account_id: str, amount_minor: int,
        session: WalletSession,
    ) -> GridTransferResult:
        """Moves `amount_minor` (in `self._config.currency`'s minor units)
        from one Grid internal account to another. `session` must be a
        verified `WalletSession` for `source_account_id` -- an
        `EMBEDDED_WALLET`-sourced quote cannot use `immediatelyExecute`
        (confirmed live: Grid rejects it outright), so this always takes
        the two-step create-quote-then-sign-and-execute path.
        """
        quote = await self._request(
            "POST", "/quotes",
            json={
                "source": {"sourceType": "ACCOUNT", "accountId": source_account_id},
                "destination": {"destinationType": "ACCOUNT", "accountId": destination_account_id},
                "lockedCurrencySide": "SENDING",
                "lockedCurrencyAmount": amount_minor,
            },
        )
        quote_id = quote["id"]
        payload_to_sign = next(
            (
                instruction["accountOrWalletInfo"]["payloadToSign"]
                for instruction in quote.get("paymentInstructions", [])
                if instruction.get("accountOrWalletInfo", {}).get("accountType") == "EMBEDDED_WALLET"
            ),
            None,
        )
        if payload_to_sign is None:
            raise GridError(f"quote {quote_id} has no EMBEDDED_WALLET payload to sign")

        signature = turnkey_stamp.build_stamp(payload_to_sign, session.keypair)
        executed = await self._request(
            "POST", f"/quotes/{quote_id}/execute",
            headers={"Grid-Wallet-Signature": signature},
        )
        return GridTransferResult(
            quote_id=quote_id, transaction_id=executed["transactionId"], status=executed["status"],
        )

    async def get_transaction_status(self, transaction_id: str) -> str:
        transaction = await self._request("GET", f"/transactions/{transaction_id}")
        return transaction["status"]

    def verify_webhook(self, body: bytes, signature_b64: str) -> dict:
        """Verifies Grid's Secp256r1 signature over the raw request body and
        returns the parsed JSON payload. Raises `GridError` if the
        signature does not verify, or if no webhook public key is
        configured at all -- a webhook endpoint that can't verify its
        sender must fail closed, not process the event anyway."""
        if not self._config.webhook_public_key_pem:
            raise GridError("REGISTRY_GRID_WEBHOOK_PUBLIC_KEY is not set")
        try:
            public_key = serialization.load_pem_public_key(
                self._config.webhook_public_key_pem.encode()
            )
            signature = base64.b64decode(signature_b64)
            public_key.verify(signature, body, ec.ECDSA(hashes.SHA256()))
        except (InvalidSignature, ValueError) as error:
            raise GridError(f"invalid webhook signature: {error}") from error
        return json.loads(body)


def rail_from_env() -> GridRail | None:
    config = config_from_env()
    if config is None:
        return None
    return GridRail(config)
