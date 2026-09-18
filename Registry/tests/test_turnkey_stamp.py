"""Self-consistency tests for the Turnkey-compatible stamp/HPKE port.

There is no real Grid enclave to test against here, so these verify the
one thing that can be verified offline: that sealing and signing are
internally consistent RFC 9180 / ECDSA-P256, by decrypting/verifying with
the same algorithm from the "other side" (a symmetric hand-rolled
recipient/verifier), the same way a real round trip against Grid would.
"""
import base64
import json

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from tipme_registry import turnkey_stamp as ts


def _decrypt_seal(sealed: dict, target_private: ec.EllipticCurvePrivateKey) -> bytes:
    """Symmetric counterpart to `_hpke_seal`, playing the recipient's role."""
    ephemeral_pub = ts._load_public_key(bytes.fromhex(sealed["encappedPublic"]))
    ephemeral_uncompressed = ts._uncompressed_bytes(ephemeral_pub)
    target_uncompressed = ts._uncompressed_bytes(target_private.public_key())

    shared_point = target_private.exchange(ec.ECDH(), ephemeral_pub)
    kem_context = ephemeral_uncompressed + target_uncompressed

    shared_secret = ts._kem_extract_and_expand(shared_point, kem_context)
    key, iv = ts._key_schedule(shared_secret)

    return AESGCM(key).decrypt(iv, bytes.fromhex(sealed["ciphertext"]), None)


def _decode_stamp(stamp: str) -> dict:
    padded = stamp.replace("-", "+").replace("_", "/")
    padded += "=" * (-len(padded) % 4)
    return json.loads(base64.b64decode(padded))


def test_build_stamp_produces_a_signature_that_verifies_against_its_own_public_key():
    keypair = ts.generate_keypair()
    stamp = ts.build_stamp("some-payload-to-sign", keypair)

    decoded = _decode_stamp(stamp)
    assert decoded["scheme"] == "SIGNATURE_SCHEME_TK_API_P256"
    assert decoded["publicKey"] == keypair.public_key_hex

    public_key = ts._load_public_key(bytes.fromhex(decoded["publicKey"]))
    public_key.verify(
        bytes.fromhex(decoded["signature"]), b"some-payload-to-sign", ec.ECDSA(hashes.SHA256()),
    )  # raises InvalidSignature on failure -- reaching here is the assertion


def test_build_stamp_is_base64url_with_no_padding():
    keypair = ts.generate_keypair()
    stamp = ts.build_stamp("payload", keypair)
    assert "+" not in stamp
    assert "/" not in stamp
    assert "=" not in stamp


def test_seal_otp_bundle_round_trips_through_a_symmetric_decrypt():
    target_private = ec.generate_private_key(ts._CURVE)
    target_public_hex = target_private.public_key().public_bytes(
        Encoding.X962, PublicFormat.CompressedPoint,
    ).hex()
    bundle = json.dumps({
        "data": json.dumps({"targetPublicKey": target_public_hex}).encode().hex(),
    })
    client_keypair = ts.generate_keypair()

    sealed = ts.seal_otp_bundle("000000", client_keypair.public_key_hex, bundle)
    plaintext = _decrypt_seal(sealed, target_private)

    assert json.loads(plaintext) == {
        "otp_code": "000000", "public_key": client_keypair.public_key_hex,
    }


def test_parse_otp_target_bundle_handles_the_unquoted_docs_style_example():
    target_hex = "02" + "ab" * 32
    inner = json.dumps({"targetPublicKey": target_hex}).encode().hex()
    # Mirrors the API docs' example formatting: single-quote-wrapped,
    # unquoted keys -- not strict JSON.
    bundle = f"'{{version:v1.0.0,data:{inner},dataSignature:deadbeef}}'"
    assert ts._parse_otp_target_bundle(bundle) == target_hex


def test_parse_otp_target_bundle_raises_a_clear_error_for_an_unrecognized_shape():
    try:
        ts._parse_otp_target_bundle('{"unexpected": "shape"}')
        assert False, "expected TurnkeyStampError"
    except ts.TurnkeyStampError as error:
        assert "data" in str(error)
