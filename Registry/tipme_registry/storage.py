"""SQLite-backed creator records.

Plain ``sqlite3`` rather than an ORM: the schema is one table, and the queries
are three. An ORM would be more code, not less.
"""
from __future__ import annotations

import secrets
import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from .handles import Handle

SCHEMA = """
CREATE TABLE IF NOT EXISTS creators (
    platform            TEXT NOT NULL,
    username            TEXT NOT NULL,
    lightning_address   TEXT NOT NULL,
    preferred_asset     TEXT NOT NULL DEFAULT 'bitcoin',
    minimum_tip_minor   INTEGER,
    display_name        TEXT,
    verified            INTEGER NOT NULL DEFAULT 0,
    -- How `verified` was earned: 'oauth' (the creator signed in with the
    -- platform itself) or 'admin' (a human checked a bio code). NULL for an
    -- unverified record. Kept for audit — verification is what makes a tip
    -- trustworthy, so how it happened should never be a mystery later.
    verified_via        TEXT,
    -- The platform's own account id, captured the moment OAuth verification
    -- succeeds. Not used to gate anything today; kept so a future re-auth can
    -- detect the id changing under an unchanged username (a sold or
    -- recycled handle) rather than silently trusting it again.
    oauth_platform_user_id TEXT,
    claim_token         TEXT,
    -- Secret issued on first registration. Required to change an existing
    -- record, so a handle cannot be taken over by whoever asks last.
    management_token    TEXT,
    -- Set when this handle was registered (or re-registered) by a signed-in
    -- TipMe user -- see app.py's `register`. NULL means "external wallet
    -- only": the record is just a directory entry pointing at someone else's
    -- Lightning wallet, with no TipMe account behind it. When set, a tip to
    -- this handle can move ledger-to-ledger instead of over Lightning -- see
    -- `POST /v1/tip/{platform}/{username}`.
    tipme_user_id       TEXT,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    PRIMARY KEY (platform, username)
);

-- Custodial accounts: TipMe holds the actual sats/USDT, so this database is
-- itself the wallet, not just a phone-book of where wallets are. See
-- accounts.py for password handling.
CREATE TABLE IF NOT EXISTS users (
    id              TEXT PRIMARY KEY,
    email           TEXT NOT NULL UNIQUE,
    password_hash   TEXT NOT NULL,
    created_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    token       TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL
);

-- One row per (user, asset). The balance a client is ever shown or allowed to
-- spend against comes from here, never from summing ledger_entries live --
-- summing on every read would make an ever-growing table a growing latency
-- cost on the one number every screen shows.
CREATE TABLE IF NOT EXISTS ledger_balances (
    user_id       TEXT NOT NULL,
    asset         TEXT NOT NULL,
    balance_minor INTEGER NOT NULL DEFAULT 0,
    updated_at    TEXT NOT NULL,
    PRIMARY KEY (user_id, asset)
);

-- Append-only audit trail behind ledger_balances. Never read on the payment
-- path; exists so any balance can be explained after the fact.
CREATE TABLE IF NOT EXISTS ledger_entries (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL,
    asset        TEXT NOT NULL,
    delta_minor  INTEGER NOT NULL,
    reason       TEXT NOT NULL,
    counterparty TEXT,
    created_at   TEXT NOT NULL
);

-- A deposit's lifecycle from "we issued an invoice" to "the ledger was
-- credited". Kept separate from ledger_entries rather than crediting on
-- invoice creation: the invoice existing proves nothing was paid yet, and an
-- external wallet may never pay it at all. `external_reference` (a payment
-- hash today; a txid for on-chain, once that exists) is what a status check
-- looks up, and its uniqueness with `method` is what makes crediting
-- idempotent -- see `complete_deposit_if_pending`.
CREATE TABLE IF NOT EXISTS pending_deposits (
    id                  TEXT PRIMARY KEY,
    user_id             TEXT NOT NULL,
    asset               TEXT NOT NULL,
    method              TEXT NOT NULL,
    external_reference  TEXT NOT NULL,
    amount_minor        INTEGER NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending',
    created_at          TEXT NOT NULL,
    completed_at        TEXT,
    UNIQUE (method, external_reference)
);

-- The next unused BIP84 derivation index for the self-managed on-chain
-- wallet (see bitcoin_chain.py). A single row, incremented atomically --
-- every deposit address and every change output needs an index that has
-- never been handed out before, or two different purposes could end up
-- spending from (or watching) the same address.
CREATE TABLE IF NOT EXISTS bitcoin_derivation (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    next_index  INTEGER NOT NULL DEFAULT 0
);

-- Maps a TipMe user to the Lightspark Grid customer + internal account
-- provisioned for them. Grid is an accounts/KYC platform, not a single
-- shared node -- see grid_rail.py's module docstring -- so unlike Voltage
-- or a Lightning node, every TipMe user who moves money through it needs
-- their own Grid customer record. Provisioned lazily, once, the first time
-- a user is party to a Grid transfer; `grid_customer_id`/`grid_account_id`
-- are then reused forever.
CREATE TABLE IF NOT EXISTS grid_customers (
    user_id           TEXT PRIMARY KEY,
    grid_customer_id  TEXT NOT NULL UNIQUE,
    grid_account_id   TEXT NOT NULL,
    currency          TEXT NOT NULL,
    created_at        TEXT NOT NULL
);

-- Tracks one Grid account-to-account transfer between two TipMe users.
-- Separate from `ledger_entries`: Grid's own ledger is the source of truth
-- for the money this table describes (unlike the bitcoin/usdt balances in
-- `ledger_balances`, which TipMe itself custodies) -- this table exists so
-- a status check or a webhook has something durable to look up and update
-- by Grid's own quote/transaction id.
CREATE TABLE IF NOT EXISTS grid_transfers (
    id                  TEXT PRIMARY KEY,
    from_user_id        TEXT NOT NULL,
    to_user_id          TEXT NOT NULL,
    grid_quote_id       TEXT NOT NULL,
    grid_transaction_id TEXT NOT NULL UNIQUE,
    currency            TEXT NOT NULL,
    amount_minor        INTEGER NOT NULL,
    status              TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL
);

-- A verified session on one Grid Embedded Wallet (Spark) account -- see
-- grid_rail.py's and turnkey_stamp.py's module docstrings for why this
-- exists at all: releasing a transfer sourced from that account needs a
-- signature from this session's key on every request, not just Basic
-- Auth. The private key lives here in plaintext, same trust level as
-- every other secret this registry already custodies (password hashes
-- aside) -- there is no separate secrets store in this codebase to put it
-- in instead. Re-verified (a new row replacing the old one) once
-- `expires_at` passes.
CREATE TABLE IF NOT EXISTS grid_wallet_sessions (
    account_id         TEXT PRIMARY KEY,
    session_private_key TEXT NOT NULL,
    session_public_key  TEXT NOT NULL,
    expires_at          TEXT NOT NULL,
    created_at          TEXT NOT NULL
);

-- A tip sent to a (platform, username) that nobody has ever claimed on
-- TipMe yet -- the "pay a friend's Instagram before they've heard of us"
-- case. Modelled on Venmo/PayPal's own answer to the identical problem
-- (send to a phone number with no account; the money sits in escrow until
-- claimed, or the sender takes it back): the sender's balance is debited
-- the instant they send, in full, with nothing about *identity* checked at
-- all -- that question is deferred entirely to whoever later registers
-- this exact handle. `status` starts 'pending' and ends exactly once, at
-- either 'claimed' (the handle got linked to a TipMe account -- see
-- `claim_pending_tips`, called from `register()`) or 'reclaimed' (the
-- sender took it back -- see `reclaim_pending_tip`); never both.
CREATE TABLE IF NOT EXISTS pending_creator_tips (
    id             TEXT PRIMARY KEY,
    platform       TEXT NOT NULL,
    username       TEXT NOT NULL,
    sender_user_id TEXT NOT NULL,
    asset          TEXT NOT NULL,
    amount_minor   INTEGER NOT NULL,
    note           TEXT,
    status         TEXT NOT NULL DEFAULT 'pending',
    created_at     TEXT NOT NULL,
    resolved_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_pending_creator_tips_handle
    ON pending_creator_tips (platform, username, status);
"""


class EmailTaken(ValueError):
    """Raised by create_user when the email is already registered."""


class InsufficientBalance(ValueError):
    """Raised by adjust_balance when a debit would take a balance below zero."""


@dataclass
class Account:
    id: str
    email: str
    created_at: datetime


@dataclass
class PendingDeposit:
    id: str
    user_id: str
    asset: str
    method: str
    external_reference: str
    amount_minor: int
    status: str
    created_at: datetime
    completed_at: datetime | None


@dataclass
class GridCustomer:
    user_id: str
    grid_customer_id: str
    grid_account_id: str
    currency: str
    created_at: datetime


@dataclass
class GridTransfer:
    id: str
    from_user_id: str
    to_user_id: str
    grid_quote_id: str
    grid_transaction_id: str
    currency: str
    amount_minor: int
    status: str
    created_at: datetime
    updated_at: datetime


@dataclass
class GridWalletSession:
    account_id: str
    session_private_key: str
    session_public_key: str
    expires_at: datetime
    created_at: datetime


@dataclass
class PendingCreatorTip:
    id: str
    platform: str
    username: str
    sender_user_id: str
    asset: str
    amount_minor: int
    note: str | None
    status: str
    created_at: datetime
    resolved_at: datetime | None


@dataclass
class CreatorRecord:
    platform: str
    username: str
    lightning_address: str
    preferred_asset: str
    minimum_tip_minor: int | None
    display_name: str | None
    verified: bool
    verified_via: str | None
    oauth_platform_user_id: str | None
    tipme_user_id: str | None
    updated_at: datetime


class Storage:
    def __init__(self, path: str):
        self.path = path
        with self.connect() as conn:
            conn.executescript(SCHEMA)
            self._migrate(conn)

    def _migrate(self, conn: sqlite3.Connection) -> None:
        """Adds columns introduced after a database already existed.

        ``CREATE TABLE IF NOT EXISTS`` only creates the table on a fresh
        database; an existing ``tipme_registry.sqlite3`` from before OAuth
        verification was added would otherwise be missing these columns
        forever.
        """
        existing = {row["name"] for row in conn.execute("PRAGMA table_info(creators)")}
        if "verified_via" not in existing:
            conn.execute("ALTER TABLE creators ADD COLUMN verified_via TEXT")
        if "oauth_platform_user_id" not in existing:
            conn.execute("ALTER TABLE creators ADD COLUMN oauth_platform_user_id TEXT")
        if "tipme_user_id" not in existing:
            conn.execute("ALTER TABLE creators ADD COLUMN tipme_user_id TEXT")

    @contextmanager
    def connect(self):
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()

    def upsert(
        self,
        handle: Handle,
        lightning_address: str,
        preferred_asset: str,
        minimum_tip_minor: int | None,
        display_name: str | None,
        claim_token: str | None,
        management_token: str | None = None,
        tipme_user_id: str | None = None,
    ) -> CreatorRecord:
        """Create or update a record.

        Callers must have already authorised the write — see
        ``authorise_write`` in app.py. This method does not check tokens; it
        only stores them.

        ``tipme_user_id`` links the handle to a signed-in TipMe account (see
        the `creators` table's own comment on the column). Passing `None`
        never *clears* an existing link -- there's no signed-out "unlink"
        action in this flow, only "this caller wasn't signed in when they
        (re)registered", which must not silently detach a handle that a
        previous, signed-in registration already linked.
        """
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            # Re-registering an existing handle deliberately clears `verified`.
            # Verification attests that a specific person controls a specific
            # wallet; changing the wallet invalidates that, and carrying the
            # badge over would let a changed record inherit trust it has not
            # earned.
            #
            # The management token is preserved on update (COALESCE keeps the
            # existing one) so a creator does not get a new secret every time
            # they change their wallet.
            conn.execute(
                """
                INSERT INTO creators (platform, username, lightning_address,
                                      preferred_asset, minimum_tip_minor,
                                      display_name, verified, verified_via,
                                      oauth_platform_user_id, claim_token,
                                      management_token, tipme_user_id,
                                      created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, ?, ?, ?, ?, ?)
                ON CONFLICT(platform, username) DO UPDATE SET
                    lightning_address = excluded.lightning_address,
                    preferred_asset   = excluded.preferred_asset,
                    minimum_tip_minor = excluded.minimum_tip_minor,
                    display_name      = excluded.display_name,
                    verified          = 0,
                    verified_via      = NULL,
                    oauth_platform_user_id = NULL,
                    claim_token       = excluded.claim_token,
                    management_token  = COALESCE(creators.management_token,
                                                 excluded.management_token),
                    tipme_user_id     = COALESCE(excluded.tipme_user_id,
                                                 creators.tipme_user_id),
                    updated_at        = excluded.updated_at
                """,
                (
                    handle.platform, handle.username, lightning_address,
                    preferred_asset, minimum_tip_minor, display_name,
                    claim_token, management_token, tipme_user_id,
                    now.isoformat(), now.isoformat(),
                ),
            )
        return self.get(handle)

    def management_token(self, handle: Handle) -> str | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT management_token FROM creators WHERE platform = ? AND username = ?",
                (handle.platform, handle.username),
            ).fetchone()
        return row["management_token"] if row else None

    def get(self, handle: Handle) -> CreatorRecord | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM creators WHERE platform = ? AND username = ?",
                (handle.platform, handle.username),
            ).fetchone()
        return self._to_record(row) if row else None

    def delete(self, handle: Handle) -> bool:
        with self.connect() as conn:
            cursor = conn.execute(
                "DELETE FROM creators WHERE platform = ? AND username = ?",
                (handle.platform, handle.username),
            )
        return cursor.rowcount > 0

    def set_verified(self, handle: Handle, verified: bool, *,
                      via: str | None = None,
                      platform_user_id: str | None = None) -> CreatorRecord | None:
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                "UPDATE creators SET verified = ?, verified_via = ?, "
                "oauth_platform_user_id = ?, updated_at = ? "
                "WHERE platform = ? AND username = ?",
                (1 if verified else 0, via if verified else None,
                 platform_user_id if verified else None,
                 now.isoformat(), handle.platform, handle.username),
            )
        return self.get(handle)

    def claim_token(self, handle: Handle) -> str | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT claim_token FROM creators WHERE platform = ? AND username = ?",
                (handle.platform, handle.username),
            ).fetchone()
        return row["claim_token"] if row else None

    @staticmethod
    def _to_record(row: sqlite3.Row) -> CreatorRecord:
        return CreatorRecord(
            platform=row["platform"],
            username=row["username"],
            lightning_address=row["lightning_address"],
            preferred_asset=row["preferred_asset"],
            minimum_tip_minor=row["minimum_tip_minor"],
            display_name=row["display_name"],
            verified=bool(row["verified"]),
            verified_via=row["verified_via"],
            oauth_platform_user_id=row["oauth_platform_user_id"],
            tipme_user_id=row["tipme_user_id"],
            updated_at=datetime.fromisoformat(row["updated_at"]),
        )

    # ----------------------------------------------------------------
    # Accounts
    # ----------------------------------------------------------------

    def create_user(self, email: str, password_hash: str) -> Account:
        user_id = secrets.token_urlsafe(16)
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            try:
                conn.execute(
                    "INSERT INTO users (id, email, password_hash, created_at) "
                    "VALUES (?, ?, ?, ?)",
                    (user_id, email, password_hash, now.isoformat()),
                )
            except sqlite3.IntegrityError as error:
                raise EmailTaken(f"{email} is already registered") from error
        return Account(id=user_id, email=email, created_at=now)

    def get_user_by_email(self, email: str) -> tuple[Account, str] | None:
        """Returns the account alongside its password hash.

        The hash is only ever needed immediately before verifying a login
        attempt, so it travels with the account here rather than through a
        separate accessor that call sites could reach for by mistake.
        """
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
        return (self._to_account(row), row["password_hash"]) if row else None

    def get_user(self, user_id: str) -> Account | None:
        with self.connect() as conn:
            row = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
        return self._to_account(row) if row else None

    @staticmethod
    def _to_account(row: sqlite3.Row) -> Account:
        return Account(
            id=row["id"],
            email=row["email"],
            created_at=datetime.fromisoformat(row["created_at"]),
        )

    # ----------------------------------------------------------------
    # Sessions
    # ----------------------------------------------------------------

    def create_session(self, user_id: str, ttl_seconds: int) -> str:
        token = secrets.token_urlsafe(32)
        now = datetime.now(timezone.utc)
        expires = now + timedelta(seconds=ttl_seconds)
        with self.connect() as conn:
            conn.execute(
                "INSERT INTO sessions (token, user_id, created_at, expires_at) "
                "VALUES (?, ?, ?, ?)",
                (token, user_id, now.isoformat(), expires.isoformat()),
            )
        return token

    def session_user_id(self, token: str) -> str | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT user_id, expires_at FROM sessions WHERE token = ?", (token,),
            ).fetchone()
        if row is None:
            return None
        if datetime.fromisoformat(row["expires_at"]) < datetime.now(timezone.utc):
            return None
        return row["user_id"]

    def delete_session(self, token: str) -> None:
        with self.connect() as conn:
            conn.execute("DELETE FROM sessions WHERE token = ?", (token,))

    # ----------------------------------------------------------------
    # Ledger
    # ----------------------------------------------------------------

    def get_balances(self, user_id: str) -> dict[str, int]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT asset, balance_minor FROM ledger_balances WHERE user_id = ?",
                (user_id,),
            ).fetchall()
        return {row["asset"]: row["balance_minor"] for row in rows}

    def adjust_balance(
        self, user_id: str, asset: str, delta_minor: int, reason: str,
        counterparty: str | None = None,
    ) -> int:
        """Credits (positive) or debits (negative) a user's ledger balance
        and records the entry, atomically.

        Rejects a debit that would take the balance below zero. This is the
        one invariant a custodial ledger cannot get wrong: nobody can ever be
        shown, let alone send, money that was never actually credited to
        them.
        """
        with self.connect() as conn:
            return self._adjust_balance(conn, user_id, asset, delta_minor, reason, counterparty)

    @staticmethod
    def _adjust_balance(
        conn: sqlite3.Connection, user_id: str, asset: str, delta_minor: int,
        reason: str, counterparty: str | None,
    ) -> int:
        """Same as `adjust_balance`, against a connection the caller already
        holds open -- so a deposit's completion and its credit happen in one
        transaction. Never call this with a connection you didn't open
        yourself; it does not commit."""
        now = datetime.now(timezone.utc)
        row = conn.execute(
            "SELECT balance_minor FROM ledger_balances WHERE user_id = ? AND asset = ?",
            (user_id, asset),
        ).fetchone()
        current = row["balance_minor"] if row else 0
        new_balance = current + delta_minor
        if new_balance < 0:
            raise InsufficientBalance(
                f"balance {current} cannot cover a change of {delta_minor}"
            )
        conn.execute(
            """
            INSERT INTO ledger_balances (user_id, asset, balance_minor, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(user_id, asset) DO UPDATE SET
                balance_minor = excluded.balance_minor,
                updated_at    = excluded.updated_at
            """,
            (user_id, asset, new_balance, now.isoformat()),
        )
        conn.execute(
            """
            INSERT INTO ledger_entries (id, user_id, asset, delta_minor, reason,
                                        counterparty, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (secrets.token_urlsafe(16), user_id, asset, delta_minor, reason,
             counterparty, now.isoformat()),
        )
        return new_balance

    # ----------------------------------------------------------------
    # Deposits
    # ----------------------------------------------------------------

    def create_pending_deposit(
        self, user_id: str, asset: str, method: str, external_reference: str, amount_minor: int,
    ) -> PendingDeposit:
        deposit_id = secrets.token_urlsafe(16)
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO pending_deposits (id, user_id, asset, method, external_reference,
                                              amount_minor, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
                """,
                (deposit_id, user_id, asset, method, external_reference, amount_minor, now.isoformat()),
            )
        return PendingDeposit(
            id=deposit_id, user_id=user_id, asset=asset, method=method,
            external_reference=external_reference, amount_minor=amount_minor,
            status="pending", created_at=now, completed_at=None,
        )

    def get_pending_deposit(self, method: str, external_reference: str) -> PendingDeposit | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM pending_deposits WHERE method = ? AND external_reference = ?",
                (method, external_reference),
            ).fetchone()
        return self._to_pending_deposit(row) if row else None

    def complete_deposit_if_pending(
        self, method: str, external_reference: str, reason: str,
    ) -> PendingDeposit | None:
        """Marks a deposit completed and credits the ledger in one
        transaction, or returns `None` without doing either if the deposit
        does not exist or was already completed.

        This is what makes crediting idempotent: a status check the app
        polls repeatedly, or a retried webhook, can call this as many times
        as it likes for the same payment and the ledger is only ever
        credited once.
        """
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM pending_deposits WHERE method = ? AND external_reference = ?",
                (method, external_reference),
            ).fetchone()
            if row is None or row["status"] != "pending":
                return None
            conn.execute(
                "UPDATE pending_deposits SET status = 'completed', completed_at = ? WHERE id = ?",
                (now.isoformat(), row["id"]),
            )
            self._adjust_balance(conn, row["user_id"], row["asset"], row["amount_minor"],
                                 reason, counterparty=None)
        return PendingDeposit(
            id=row["id"], user_id=row["user_id"], asset=row["asset"], method=row["method"],
            external_reference=row["external_reference"], amount_minor=row["amount_minor"],
            status="completed", created_at=datetime.fromisoformat(row["created_at"]),
            completed_at=now,
        )

    def list_ledger_entries(self, user_id: str, limit: int = 50) -> list[dict]:
        """Newest-first history for one account, with each counterparty turned
        into something a person can read ("@handle") rather than an internal
        user id."""
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT id, asset, delta_minor, reason, counterparty, created_at "
                "FROM ledger_entries WHERE user_id = ? ORDER BY created_at DESC, rowid DESC LIMIT ?",
                (user_id, limit),
            ).fetchall()
            entries = []
            for row in rows:
                counterparty = row["counterparty"]
                if counterparty and ":" in counterparty:
                    counterparty = "@" + counterparty.split(":", 1)[1]
                elif counterparty:
                    creator = conn.execute(
                        "SELECT username FROM creators WHERE tipme_user_id = ? LIMIT 1",
                        (counterparty,),
                    ).fetchone()
                    counterparty = "@" + creator["username"] if creator else "a TipMe user"
                entries.append({
                    "id": row["id"], "asset": row["asset"], "delta_minor": row["delta_minor"],
                    "reason": row["reason"], "counterparty": counterparty,
                    "created_at": datetime.fromisoformat(row["created_at"]).replace(microsecond=0),
                })
        return entries

    def transfer_balance(
        self, from_user_id: str, to_user_id: str, asset: str, amount_minor: int,
    ) -> None:
        """Moves `amount_minor` of `asset` from one TipMe account's ledger
        straight to another's, in one database transaction -- no Lightning,
        no on-chain, no network at all. This is the "internal transfer"
        case: when both sender and recipient already hold custodial TipMe
        balances, there is nothing to route anywhere, only two numbers to
        update together. Raises `InsufficientBalance` (leaving both
        balances untouched) if the sender can't cover it.
        """
        with self.connect() as conn:
            self._adjust_balance(conn, from_user_id, asset, -amount_minor,
                                 "internal_transfer_sent", counterparty=to_user_id)
            self._adjust_balance(conn, to_user_id, asset, amount_minor,
                                 "internal_transfer_received", counterparty=from_user_id)

    # ----------------------------------------------------------------
    # Pending tips -- money sent to a handle nobody has claimed yet
    # ----------------------------------------------------------------

    def create_pending_tip(
        self, platform: str, username: str, sender_user_id: str, asset: str,
        amount_minor: int, note: str | None,
    ) -> PendingCreatorTip:
        """Debits the sender and records an escrowed tip in one transaction.

        Called only for a (platform, username) with no `creators` row at
        all -- see `tip_pending` in app.py. A handle that has registered,
        even without linking a TipMe account, already has a real
        `lightning_address` to pay instead; escrow exists for the case
        where there is genuinely nowhere else to send the money yet.
        """
        tip_id = secrets.token_urlsafe(16)
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            self._adjust_balance(
                conn, sender_user_id, asset, -amount_minor,
                "pending_tip_sent", counterparty=f"{platform}:{username}",
            )
            conn.execute(
                """
                INSERT INTO pending_creator_tips
                    (id, platform, username, sender_user_id, asset, amount_minor,
                     note, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
                """,
                (tip_id, platform, username, sender_user_id, asset, amount_minor,
                 note, now.isoformat()),
            )
        return PendingCreatorTip(
            id=tip_id, platform=platform, username=username, sender_user_id=sender_user_id,
            asset=asset, amount_minor=amount_minor, note=note, status="pending",
            created_at=now, resolved_at=None,
        )

    def claim_pending_tips(self, platform: str, username: str, user_id: str) -> list[PendingCreatorTip]:
        """Credits `user_id`'s ledger with every still-pending tip addressed
        to (platform, username) and marks each claimed, atomically per tip.

        Called from `register()` the moment this exact handle is newly
        linked to a TipMe account. This is the other half of the escrow: a
        tip sent before its recipient ever signed up lands the instant they
        do, with no action required from whoever sent it.
        """
        now = datetime.now(timezone.utc)
        claimed: list[PendingCreatorTip] = []
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM pending_creator_tips
                WHERE platform = ? AND username = ? AND status = 'pending'
                """,
                (platform, username),
            ).fetchall()
            for row in rows:
                self._adjust_balance(
                    conn, user_id, row["asset"], row["amount_minor"],
                    "pending_tip_claimed", counterparty=row["sender_user_id"],
                )
                conn.execute(
                    "UPDATE pending_creator_tips SET status = 'claimed', resolved_at = ? WHERE id = ?",
                    (now.isoformat(), row["id"]),
                )
                claimed.append(self._to_pending_tip(row, status="claimed", resolved_at=now))
        return claimed

    def list_pending_tips_sent(self, sender_user_id: str) -> list[PendingCreatorTip]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM pending_creator_tips WHERE sender_user_id = ? ORDER BY created_at DESC",
                (sender_user_id,),
            ).fetchall()
        return [self._to_pending_tip(row) for row in rows]

    def reclaim_pending_tip(self, tip_id: str, sender_user_id: str) -> PendingCreatorTip | None:
        """Refunds an unclaimed pending tip back to whoever sent it --
        Venmo's "take back" for the identical situation, available any time
        before the recipient claims it. Returns `None`, changing nothing,
        if the tip doesn't exist, was already resolved, or belongs to a
        different sender.
        """
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM pending_creator_tips WHERE id = ?", (tip_id,),
            ).fetchone()
            if row is None or row["status"] != "pending" or row["sender_user_id"] != sender_user_id:
                return None
            self._adjust_balance(
                conn, sender_user_id, row["asset"], row["amount_minor"],
                "pending_tip_reclaimed", counterparty=f"{row['platform']}:{row['username']}",
            )
            conn.execute(
                "UPDATE pending_creator_tips SET status = 'reclaimed', resolved_at = ? WHERE id = ?",
                (now.isoformat(), tip_id),
            )
        return self._to_pending_tip(row, status="reclaimed", resolved_at=now)

    @staticmethod
    def _to_pending_tip(
        row: sqlite3.Row, status: str | None = None, resolved_at: datetime | None = None,
    ) -> PendingCreatorTip:
        return PendingCreatorTip(
            id=row["id"], platform=row["platform"], username=row["username"],
            sender_user_id=row["sender_user_id"], asset=row["asset"],
            amount_minor=row["amount_minor"], note=row["note"],
            status=status if status is not None else row["status"],
            created_at=datetime.fromisoformat(row["created_at"]),
            resolved_at=resolved_at if resolved_at is not None else (
                datetime.fromisoformat(row["resolved_at"]) if row["resolved_at"] else None
            ),
        )

    def complete_deposit_with_amount(
        self, method: str, external_reference: str, observed_amount_minor: int, reason: str,
    ) -> PendingDeposit | None:
        """Same idempotency guarantee as `complete_deposit_if_pending`, for a
        rail where the deposited amount isn't known until it's observed on
        arrival (an on-chain address can receive any amount, unlike a
        fixed-amount Lightning invoice) -- credits `observed_amount_minor`
        rather than whatever amount_minor the deposit was created with.
        """
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM pending_deposits WHERE method = ? AND external_reference = ?",
                (method, external_reference),
            ).fetchone()
            if row is None or row["status"] != "pending":
                return None
            conn.execute(
                "UPDATE pending_deposits SET status = 'completed', completed_at = ?, "
                "amount_minor = ? WHERE id = ?",
                (now.isoformat(), observed_amount_minor, row["id"]),
            )
            self._adjust_balance(conn, row["user_id"], row["asset"], observed_amount_minor,
                                 reason, counterparty=None)
        return PendingDeposit(
            id=row["id"], user_id=row["user_id"], asset=row["asset"], method=row["method"],
            external_reference=row["external_reference"], amount_minor=observed_amount_minor,
            status="completed", created_at=datetime.fromisoformat(row["created_at"]),
            completed_at=now,
        )

    # ----------------------------------------------------------------
    # On-chain Bitcoin address derivation
    # ----------------------------------------------------------------

    def next_bitcoin_index(self) -> int:
        """Hands out the next never-before-used BIP84 derivation index and
        advances the counter, atomically. Used for both fresh deposit
        addresses and withdrawal change outputs -- either way, once an index
        is handed out it is never handed out again.
        """
        with self.connect() as conn:
            conn.execute("INSERT OR IGNORE INTO bitcoin_derivation (id, next_index) VALUES (1, 0)")
            row = conn.execute("SELECT next_index FROM bitcoin_derivation WHERE id = 1").fetchone()
            index = row["next_index"]
            conn.execute("UPDATE bitcoin_derivation SET next_index = ? WHERE id = 1", (index + 1,))
        return index

    def bitcoin_index_count(self) -> int:
        """How many indices have ever been handed out -- i.e. the exclusive
        upper bound of indices worth scanning for spendable UTXOs."""
        with self.connect() as conn:
            row = conn.execute("SELECT next_index FROM bitcoin_derivation WHERE id = 1").fetchone()
        return row["next_index"] if row else 0

    @staticmethod
    def _to_pending_deposit(row: sqlite3.Row) -> PendingDeposit:
        return PendingDeposit(
            id=row["id"], user_id=row["user_id"], asset=row["asset"], method=row["method"],
            external_reference=row["external_reference"], amount_minor=row["amount_minor"],
            status=row["status"], created_at=datetime.fromisoformat(row["created_at"]),
            completed_at=datetime.fromisoformat(row["completed_at"]) if row["completed_at"] else None,
        )

    # ----------------------------------------------------------------
    # Lightspark Grid
    # ----------------------------------------------------------------

    def get_grid_customer(self, user_id: str) -> GridCustomer | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM grid_customers WHERE user_id = ?", (user_id,),
            ).fetchone()
        return self._to_grid_customer(row) if row else None

    def record_grid_customer(
        self, user_id: str, grid_customer_id: str, grid_account_id: str, currency: str,
    ) -> GridCustomer:
        """Persists the mapping the first time a user is provisioned on
        Grid. Idempotent by `user_id`: a second call (e.g. a race between
        two requests provisioning the same user) leaves the first mapping
        in place rather than creating a second Grid customer's worth of
        orphaned state.
        """
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO grid_customers (user_id, grid_customer_id, grid_account_id,
                                            currency, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO NOTHING
                """,
                (user_id, grid_customer_id, grid_account_id, currency, now.isoformat()),
            )
            row = conn.execute(
                "SELECT * FROM grid_customers WHERE user_id = ?", (user_id,),
            ).fetchone()
        return self._to_grid_customer(row)

    def record_grid_transfer(
        self, from_user_id: str, to_user_id: str, grid_quote_id: str,
        grid_transaction_id: str, currency: str, amount_minor: int, status: str,
    ) -> GridTransfer:
        record_id = secrets.token_urlsafe(16)
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO grid_transfers (id, from_user_id, to_user_id, grid_quote_id,
                                            grid_transaction_id, currency, amount_minor,
                                            status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (record_id, from_user_id, to_user_id, grid_quote_id, grid_transaction_id,
                 currency, amount_minor, status, now.isoformat(), now.isoformat()),
            )
        return GridTransfer(
            id=record_id, from_user_id=from_user_id, to_user_id=to_user_id,
            grid_quote_id=grid_quote_id, grid_transaction_id=grid_transaction_id,
            currency=currency, amount_minor=amount_minor, status=status,
            created_at=now, updated_at=now,
        )

    def get_grid_transfer(self, grid_transaction_id: str) -> GridTransfer | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM grid_transfers WHERE grid_transaction_id = ?",
                (grid_transaction_id,),
            ).fetchone()
        return self._to_grid_transfer(row) if row else None

    def update_grid_transfer_status(
        self, grid_transaction_id: str, status: str,
    ) -> GridTransfer | None:
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                "UPDATE grid_transfers SET status = ?, updated_at = ? "
                "WHERE grid_transaction_id = ?",
                (status, now.isoformat(), grid_transaction_id),
            )
            row = conn.execute(
                "SELECT * FROM grid_transfers WHERE grid_transaction_id = ?",
                (grid_transaction_id,),
            ).fetchone()
        return self._to_grid_transfer(row) if row else None

    @staticmethod
    def _to_grid_customer(row: sqlite3.Row) -> GridCustomer:
        return GridCustomer(
            user_id=row["user_id"], grid_customer_id=row["grid_customer_id"],
            grid_account_id=row["grid_account_id"], currency=row["currency"],
            created_at=datetime.fromisoformat(row["created_at"]),
        )

    @staticmethod
    def _to_grid_transfer(row: sqlite3.Row) -> GridTransfer:
        return GridTransfer(
            id=row["id"], from_user_id=row["from_user_id"], to_user_id=row["to_user_id"],
            grid_quote_id=row["grid_quote_id"], grid_transaction_id=row["grid_transaction_id"],
            currency=row["currency"], amount_minor=row["amount_minor"], status=row["status"],
            created_at=datetime.fromisoformat(row["created_at"]),
            updated_at=datetime.fromisoformat(row["updated_at"]),
        )

    def get_grid_wallet_session(self, account_id: str) -> GridWalletSession | None:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM grid_wallet_sessions WHERE account_id = ?", (account_id,),
            ).fetchone()
        return self._to_grid_wallet_session(row) if row else None

    def record_grid_wallet_session(
        self, account_id: str, session_private_key: str, session_public_key: str,
        expires_at: datetime,
    ) -> GridWalletSession:
        """Replaces any previous session for this account -- a fresh
        verification always supersedes an old one, whether the old one
        merely expired or is simply being renewed early."""
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO grid_wallet_sessions (account_id, session_private_key,
                                                  session_public_key, expires_at, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                    session_private_key = excluded.session_private_key,
                    session_public_key  = excluded.session_public_key,
                    expires_at          = excluded.expires_at,
                    created_at          = excluded.created_at
                """,
                (account_id, session_private_key, session_public_key,
                 expires_at.isoformat(), now.isoformat()),
            )
        return GridWalletSession(
            account_id=account_id, session_private_key=session_private_key,
            session_public_key=session_public_key, expires_at=expires_at, created_at=now,
        )

    @staticmethod
    def _to_grid_wallet_session(row: sqlite3.Row) -> GridWalletSession:
        return GridWalletSession(
            account_id=row["account_id"], session_private_key=row["session_private_key"],
            session_public_key=row["session_public_key"],
            expires_at=datetime.fromisoformat(row["expires_at"]),
            created_at=datetime.fromisoformat(row["created_at"]),
        )
