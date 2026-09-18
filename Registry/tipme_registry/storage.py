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
    -- platform itself), 'admin' (a human checked a bio code), 'link' (the
    -- registry fetched a page the creator submitted and found the claim
    -- code in it -- see page_metadata.py), or 'dev-auto' (skipped entirely,
    -- REGISTRY_AUTO_VERIFY_LINKS=1 -- must never be set where real money
    -- moves). NULL for an unverified record. Kept for audit — verification
    -- is what makes a tip trustworthy, so how it happened should never be
    -- a mystery later.
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
    -- Set when this handle is linked straight to a TipMe account's own
    -- balance rather than an external Lightning address (see
    -- POST /v1/me/creators). A tip to a record like this never touches the
    -- Lightning network at all -- it is a ledger transfer between two rows
    -- in this same database, which is also why it needs none of the
    -- external-send machinery that is not built yet. `lightning_address` is
    -- an empty string (not NULL -- see the NOT NULL above, kept rather than
    -- relaxed to avoid a table-rebuild migration) for a record like this;
    -- callers must check `tipme_user_id` first, never assume the address is
    -- meaningful just because it is present.
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

-- Forgot-password codes. Short-lived and single-use on purpose: this is a
-- second, weaker credential that unlocks the same account as the password
-- itself, so it gets the same "expires soon, works once" treatment a
-- management token or OAuth state does elsewhere in this file.
CREATE TABLE IF NOT EXISTS password_resets (
    code        TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL,
    created_at  TEXT NOT NULL,
    expires_at  TEXT NOT NULL,
    used        INTEGER NOT NULL DEFAULT 0
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

    @property
    def is_tipme_account(self) -> bool:
        return self.tipme_user_id is not None


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

    def link_to_tipme_account(
        self,
        handle: Handle,
        user_id: str,
        preferred_asset: str,
        minimum_tip_minor: int | None,
        display_name: str | None,
        claim_token: str,
    ) -> CreatorRecord:
        """Links a handle straight to a TipMe account's own balance.

        Unlike `upsert`, there is no external address to store or verify --
        the destination *is* the account, so a tip here is a ledger
        transfer between two rows in this database, never a real Lightning
        send. Ownership of that account is already proven by the session
        token this requires (see app.py's `/v1/me/creators`); what is not
        proven is that the caller actually controls the social handle being
        claimed -- the same trust gap `upsert`'s anonymous claim has -- so
        this starts unverified too, upgradable through the same bio-code +
        admin `/verify` path.
        """
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO creators (platform, username, lightning_address,
                                      preferred_asset, minimum_tip_minor,
                                      display_name, verified, verified_via,
                                      oauth_platform_user_id, claim_token,
                                      management_token, tipme_user_id,
                                      created_at, updated_at)
                VALUES (?, ?, '', ?, ?, ?, 0, NULL, NULL, ?, NULL, ?, ?, ?)
                ON CONFLICT(platform, username) DO UPDATE SET
                    lightning_address = '',
                    preferred_asset   = excluded.preferred_asset,
                    minimum_tip_minor = excluded.minimum_tip_minor,
                    display_name      = excluded.display_name,
                    verified          = 0,
                    verified_via      = NULL,
                    oauth_platform_user_id = NULL,
                    claim_token       = excluded.claim_token,
                    management_token  = NULL,
                    tipme_user_id     = excluded.tipme_user_id,
                    updated_at        = excluded.updated_at
                """,
                (
                    handle.platform, handle.username, preferred_asset,
                    minimum_tip_minor, display_name, claim_token, user_id,
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

    def delete_sessions_for_user(self, user_id: str, except_token: str | None = None) -> None:
        """Logs a user out everywhere -- used after a password change or
        reset, since a credential that just changed hands (or was just
        proven) is exactly the moment every *other* session should stop
        trusting the old one. `except_token` keeps the session that just
        authenticated the change alive, so changing your own password does
        not also log out the device you changed it from."""
        with self.connect() as conn:
            if except_token:
                conn.execute(
                    "DELETE FROM sessions WHERE user_id = ? AND token != ?",
                    (user_id, except_token),
                )
            else:
                conn.execute("DELETE FROM sessions WHERE user_id = ?", (user_id,))

    def update_password(self, user_id: str, password_hash: str) -> None:
        with self.connect() as conn:
            conn.execute(
                "UPDATE users SET password_hash = ? WHERE id = ?",
                (password_hash, user_id),
            )

    # ----------------------------------------------------------------
    # Password resets
    # ----------------------------------------------------------------

    def create_password_reset(self, user_id: str, ttl_seconds: int) -> str:
        # Uppercase hex rather than token_urlsafe: this one gets typed by
        # hand from an email, so it skips the mixed-case/punctuation
        # alphabet that makes token_urlsafe good for machine-to-machine
        # secrets and bad for human ones.
        code = secrets.token_hex(4).upper()
        now = datetime.now(timezone.utc)
        expires = now + timedelta(seconds=ttl_seconds)
        with self.connect() as conn:
            conn.execute(
                "INSERT INTO password_resets (code, user_id, created_at, expires_at, used) "
                "VALUES (?, ?, ?, ?, 0)",
                (code, user_id, now.isoformat(), expires.isoformat()),
            )
        return code

    def consume_password_reset(self, code: str) -> str | None:
        """Returns the user id the code was issued for, and marks it spent
        -- atomically enough for a single-process SQLite deployment, since
        this connection is the only writer. Returns None for a code that
        does not exist, already used, or expired, so a reset attempt with a
        bad code fails the same way regardless of which of those it was."""
        with self.connect() as conn:
            row = conn.execute(
                "SELECT user_id, expires_at, used FROM password_resets WHERE code = ?",
                (code,),
            ).fetchone()
            if row is None or row["used"]:
                return None
            if datetime.fromisoformat(row["expires_at"]) < datetime.now(timezone.utc):
                return None
            conn.execute("UPDATE password_resets SET used = 1 WHERE code = ?", (code,))
        return row["user_id"]

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
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
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

    def transfer_balance(
        self, from_user_id: str, to_user_id: str, asset: str, amount_minor: int,
        reason: str, from_counterparty: str | None = None, to_counterparty: str | None = None,
    ) -> None:
        """Moves money between two TipMe accounts' ledgers in one
        transaction -- the debit and credit either both happen or neither
        does, which calling `adjust_balance` twice cannot guarantee (a crash
        between the two calls would burn or duplicate the amount). This is
        what makes a TipMe-to-TipMe tip real without ever touching the
        Lightning network: the whole payment *is* these two rows changing
        together.
        """
        if amount_minor <= 0:
            raise ValueError("transfer amount must be positive")
        if from_user_id == to_user_id:
            # Not just a no-op to reject: the read-both-then-write-both
            # shape below would have the second write clobber the first
            # for a single (user_id, asset) row, silently losing the debit.
            raise ValueError("cannot transfer to the same account")

        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            sender_row = conn.execute(
                "SELECT balance_minor FROM ledger_balances WHERE user_id = ? AND asset = ?",
                (from_user_id, asset),
            ).fetchone()
            sender_balance = sender_row["balance_minor"] if sender_row else 0
            new_sender_balance = sender_balance - amount_minor
            if new_sender_balance < 0:
                raise InsufficientBalance(
                    f"balance {sender_balance} cannot cover a send of {amount_minor}"
                )

            receiver_row = conn.execute(
                "SELECT balance_minor FROM ledger_balances WHERE user_id = ? AND asset = ?",
                (to_user_id, asset),
            ).fetchone()
            receiver_balance = receiver_row["balance_minor"] if receiver_row else 0
            new_receiver_balance = receiver_balance + amount_minor

            for user_id, new_balance in ((from_user_id, new_sender_balance),
                                         (to_user_id, new_receiver_balance)):
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

            for user_id, delta, counterparty in (
                (from_user_id, -amount_minor, from_counterparty),
                (to_user_id, amount_minor, to_counterparty),
            ):
                conn.execute(
                    """
                    INSERT INTO ledger_entries (id, user_id, asset, delta_minor, reason,
                                                counterparty, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (secrets.token_urlsafe(16), user_id, asset, delta, reason,
                     counterparty, now.isoformat()),
                )
