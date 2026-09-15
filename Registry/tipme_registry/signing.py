"""Ed25519 signing of registry responses.

Why responses are signed at all, when they already travel over TLS: the
registry's answer *is* the destination of the money. TLS authenticates the
connection to whoever currently holds a certificate for the hostname, which is
not the same as authenticating the record. A compromised CDN edge, a
mis-issued certificate, or a hijacked DNS entry would otherwise be able to
swap a creator's Lightning address for an attacker's, silently, for every
sender in the app. The client verifies this signature before a single field
reaches its payment path.

The signature covers the exact JSON bytes that are transmitted, not a
re-serialisation of them, so client and server cannot disagree about
canonicalisation.
"""
from __future__ import annotations

import base64
import json
from datetime import datetime, timezone

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


def generate_keypair() -> tuple[str, str]:
    """Returns (private_key_b64, public_key_b64).

    The public half goes into the app's ``TIPME_REGISTRY_PUBLIC_KEY``; the
    private half goes into the registry's environment and nowhere else.
    """
    private = Ed25519PrivateKey.generate()
    private_bytes = private.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_bytes = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return (
        base64.b64encode(private_bytes).decode(),
        base64.b64encode(public_bytes).decode(),
    )


def load_private_key(private_key_b64: str) -> Ed25519PrivateKey:
    return Ed25519PrivateKey.from_private_bytes(base64.b64decode(private_key_b64))


def public_key_b64(private_key: Ed25519PrivateKey) -> str:
    raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return base64.b64encode(raw).decode()


def iso8601(value: datetime) -> str:
    """RFC3339 with no fractional seconds.

    Swift's ``JSONDecoder.dateDecodingStrategy = .iso8601`` uses
    ``ISO8601DateFormatter`` with ``.withInternetDateTime`` only, which rejects
    fractional seconds outright. Emitting ``...T22:30:00.123456Z`` here makes
    every record fail to decode on the client, so the truncation is required
    rather than cosmetic.
    """
    return (
        value.astimezone(timezone.utc)
        .replace(microsecond=0)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def sign_payload(private_key: Ed25519PrivateKey, payload: dict) -> dict:
    """Produces the envelope the iOS ``RegistryClient`` expects.

    ``separators`` and ``sort_keys`` keep the bytes deterministic, which makes
    the signature reproducible for debugging; the client verifies whatever
    bytes arrive rather than re-deriving them, so this is for our benefit.
    """
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    signature = private_key.sign(body)
    return {
        "payload": base64.b64encode(body).decode(),
        "signature": base64.b64encode(signature).decode(),
    }


def verify_envelope(public_key_b64_value: str, envelope: dict) -> dict:
    """Server-side mirror of the client check. Used in tests to prove the two
    halves agree, and by the ``verify`` CLI for debugging a live registry."""
    public = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key_b64_value))
    body = base64.b64decode(envelope["payload"])
    public.verify(base64.b64decode(envelope["signature"]), body)
    return json.loads(body)
