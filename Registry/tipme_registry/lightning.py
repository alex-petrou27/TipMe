"""Lightning address validation.

Mirrors ``LightningAddress`` in the iOS core. A permissive parser here is a
payment-redirection bug: whatever a creator stores is where senders' money goes.
"""
from __future__ import annotations

NAME_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789._-+")
DOMAIN_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789.-")


class InvalidLightningAddress(ValueError):
    pass


def normalise(raw: str) -> str:
    value = (raw or "").strip().lower()
    if value.startswith("lightning:"):
        value = value[len("lightning:"):]

    parts = value.split("@")
    if len(parts) != 2:
        raise InvalidLightningAddress("expected exactly one '@'")

    name, domain = parts

    if not name or len(name) > 64:
        raise InvalidLightningAddress("name must be 1-64 characters")
    if ".." in name or not set(name) <= NAME_CHARS:
        raise InvalidLightningAddress("name contains disallowed characters")

    if not domain or len(domain) > 253:
        raise InvalidLightningAddress("domain must be 1-253 characters")
    if "." not in domain:
        raise InvalidLightningAddress("domain must be dotted")
    if domain.startswith(".") or domain.endswith(".") or ".." in domain:
        raise InvalidLightningAddress("malformed domain")
    if not set(domain) <= DOMAIN_CHARS:
        raise InvalidLightningAddress("domain contains disallowed characters")

    return f"{name}@{domain}"


def redact(address: str) -> str:
    """For logs. The registry knows who tips whom; its logs should not."""
    name, _, domain = address.partition("@")
    return f"{name[:2]}***@{domain}"
