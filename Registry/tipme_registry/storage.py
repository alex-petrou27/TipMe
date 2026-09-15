"""SQLite-backed creator records.

Plain ``sqlite3`` rather than an ORM: the schema is one table, and the queries
are three. An ORM would be more code, not less.
"""
from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone

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
    claim_token         TEXT,
    -- Secret issued on first registration. Required to change an existing
    -- record, so a handle cannot be taken over by whoever asks last.
    management_token    TEXT,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    PRIMARY KEY (platform, username)
);
"""


@dataclass
class CreatorRecord:
    platform: str
    username: str
    lightning_address: str
    preferred_asset: str
    minimum_tip_minor: int | None
    display_name: str | None
    verified: bool
    updated_at: datetime


class Storage:
    def __init__(self, path: str):
        self.path = path
        with self.connect() as conn:
            conn.executescript(SCHEMA)

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
                                      display_name, verified, claim_token,
                                      management_token, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                ON CONFLICT(platform, username) DO UPDATE SET
                    lightning_address = excluded.lightning_address,
                    preferred_asset   = excluded.preferred_asset,
                    minimum_tip_minor = excluded.minimum_tip_minor,
                    display_name      = excluded.display_name,
                    verified          = 0,
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

    def set_verified(self, handle: Handle, verified: bool) -> CreatorRecord | None:
        now = datetime.now(timezone.utc)
        with self.connect() as conn:
            conn.execute(
                "UPDATE creators SET verified = ?, updated_at = ? "
                "WHERE platform = ? AND username = ?",
                (1 if verified else 0, now.isoformat(), handle.platform, handle.username),
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
            updated_at=datetime.fromisoformat(row["updated_at"]),
        )
