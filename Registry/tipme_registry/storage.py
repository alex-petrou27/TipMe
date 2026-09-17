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
    ) -> CreatorRecord:
        """Create or update a record.

        Callers must have already authorised the write — see
        ``authorise_write`` in app.py. This method does not check tokens; it
        only stores them.
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
                                      management_token, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, NULL, NULL, ?, ?, ?, ?)
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
                    updated_at        = excluded.updated_at
                """,
                (
                    handle.platform, handle.username, lightning_address,
                    preferred_asset, minimum_tip_minor, display_name,
                    claim_token, management_token, now.isoformat(), now.isoformat(),
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
