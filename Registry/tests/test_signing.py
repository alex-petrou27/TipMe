import base64
import json
import re
from datetime import datetime, timezone

import pytest
from cryptography.exceptions import InvalidSignature

from tipme_registry import signing


def test_sign_and_verify_round_trip():
    private_b64, public_b64 = signing.generate_keypair()
    private = signing.load_private_key(private_b64)

    envelope = signing.sign_payload(private, {"username": "creator"})
    assert signing.verify_envelope(public_b64, envelope) == {"username": "creator"}


def test_signature_from_another_key_is_rejected():
    """The attack: a hostile network or hijacked DNS swapping the creator's
    address for an attacker's. TLS alone would not stop it."""
    _, honest_public = signing.generate_keypair()
    attacker_private_b64, _ = signing.generate_keypair()
    attacker = signing.load_private_key(attacker_private_b64)

    envelope = signing.sign_payload(attacker, {"lightning_address": "attacker@evil.example"})
    with pytest.raises(InvalidSignature):
        signing.verify_envelope(honest_public, envelope)


def test_tampered_payload_is_rejected():
    private_b64, public_b64 = signing.generate_keypair()
    private = signing.load_private_key(private_b64)

    envelope = signing.sign_payload(private, {"lightning_address": "creator@getalby.com"})
    tampered = json.dumps({"lightning_address": "attacker@evil.example"}).encode()
    envelope["payload"] = base64.b64encode(tampered).decode()

    with pytest.raises(InvalidSignature):
        signing.verify_envelope(public_b64, envelope)


def test_timestamps_carry_no_fractional_seconds():
    """Swift's JSONDecoder .iso8601 strategy uses ISO8601DateFormatter with
    .withInternetDateTime only, which rejects fractional seconds. Emitting
    microseconds here makes every record fail to decode on the client."""
    value = datetime(2026, 9, 15, 22, 30, 0, 123_456, tzinfo=timezone.utc)
    formatted = signing.iso8601(value)

    assert formatted == "2026-09-15T22:30:00Z"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", formatted)


def test_timestamps_are_normalised_to_utc():
    from datetime import timedelta
    tz = timezone(timedelta(hours=5, minutes=30))
    value = datetime(2026, 9, 15, 4, 0, 0, tzinfo=tz)
    assert signing.iso8601(value) == "2026-09-14T22:30:00Z"
