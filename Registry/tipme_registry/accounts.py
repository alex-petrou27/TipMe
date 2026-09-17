"""Email/password accounts.

TipMe is a custodial wallet: a user's balance lives in this server's ledger,
not in a wallet only they hold the keys to. That makes the password the only
thing standing between an attacker and someone else's money, so hashing and
validation live in one place rather than being reimplemented at each call
site.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
from base64 import b64decode, b64encode

MIN_PASSWORD_LENGTH = 8

# Deliberately permissive: RFC 5322 in full is not worth the false rejections
# it causes. This catches the mistakes that matter (no @, no domain) without
# rejecting real addresses.
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# scrypt cost parameters. n=2**14 is the library's own recommended minimum
# for interactive logins as of this writing -- expensive enough to make
# offline brute-forcing a stolen hash slow, cheap enough not to make a login
# noticeably slow.
_SCRYPT_N = 2**14
_SCRYPT_R = 8
_SCRYPT_P = 1
_SCRYPT_DKLEN = 32


class InvalidEmail(ValueError):
    """Raised when a string could never be a deliverable email address."""


class WeakPassword(ValueError):
    """Raised when a password does not meet the minimum bar."""


def normalise_email(raw: str) -> str:
    """Validates and lower-cases an email address.

    Lower-casing matters here specifically because two accounts differing
    only in case would otherwise be able to coexist, silently splitting one
    person's tips across two balances depending on how they typed their
    email that day.
    """
    email = (raw or "").strip().lower()
    if not email or not _EMAIL_RE.match(email):
        raise InvalidEmail("not a valid email address")
    return email


def validate_password(password: str) -> None:
    if not password or len(password) < MIN_PASSWORD_LENGTH:
        raise WeakPassword(f"password must be at least {MIN_PASSWORD_LENGTH} characters")


def hash_password(password: str) -> str:
    """Returns ``salt:digest``, both base64, for storage."""
    salt = os.urandom(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"), salt=salt,
        n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=_SCRYPT_DKLEN,
    )
    return f"{b64encode(salt).decode()}:{b64encode(digest).decode()}"


def verify_password(password: str, stored: str) -> bool:
    """Constant-time check against a hash produced by ``hash_password``.

    Never raises on a malformed stored value -- a corrupt hash should fail
    the login, not crash the request.
    """
    try:
        salt_b64, digest_b64 = stored.split(":", 1)
        salt = b64decode(salt_b64)
        expected = b64decode(digest_b64)
    except (ValueError, TypeError):
        return False
    actual = hashlib.scrypt(
        password.encode("utf-8"), salt=salt,
        n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=_SCRYPT_DKLEN,
    )
    return hmac.compare_digest(actual, expected)
