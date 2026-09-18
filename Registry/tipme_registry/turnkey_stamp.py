"""Turnkey-compatible API-key stamps and HPKE sealing for Grid's Embedded
Wallet auth flow.

## Why this exists

Grid's Embedded Wallet (Spark) accounts are self-custodial: Grid never holds
the key that authorizes moving money out of one. Releasing a transfer means
proving control of a "session signing key" over each request, via a header
Grid calls `Grid-Wallet-Signature` -- and the wire format of that header,
and of the OTP verification payload underneath it, is not actually a Grid
invention. Grid's embedded-wallet infrastructure is built on Turnkey
(`ACTIVITY_TYPE_...`, `organizationId`, `SIGNATURE_SCHEME_TK_API_P256` are
all Turnkey's own naming), and there is no Python SDK for it -- Turnkey
ships Go/Rust/JS/Elixir clients only. This module is a from-scratch,
byte-for-byte port of Turnkey's own JS packages
(`@turnkey/api-key-stamper`, `@turnkey/crypto`, both fetched and read
directly from the npm registry -- not guessed from documentation prose),
covering the two primitives Grid's auth flow needs:

- `build_stamp`: the ECDSA-P256 "API-key stamp" carried in
  `Grid-Wallet-Signature` on every signed request (credential
  registration, verification, and quote execution alike).
- `seal_otp_bundle`: HPKE-sealing `{"otp_code", "public_key"}` to the
  target public key Grid returns in `otpEncryptionTargetBundle`, so the
  OTP code Grid "sends" (in sandbox, the fixed code `"000000"`) never
  crosses the wire in plaintext.

## Why this is hand-rolled instead of using an HPKE library

The seal here is RFC 9180 base-mode HPKE with a standard suite
(DHKEM(P-256, HKDF-SHA256), HKDF-SHA256, AES-256-GCM), computed directly
from the spec (`_kem_extract_and_expand`, `_key_schedule`, both checked
against the official RFC 9180 test vectors for this exact suite) rather
than via a library, so nothing about the derivation depends on a
library's particular conventions. Two wrong guesses along the way, each
found by testing live against a real sandbox account and reading Grid's
own `mintlify/snippets/global-accounts/client-keys.mdx` guide (fetched
from the `lightsparkdev/grid-api` repo directly -- the rendered docs site
blocks this sandbox's egress) rather than the OpenAPI spec's prose alone:

1. `encappedPublic` must be the ephemeral key **uncompressed**, not
   compressed -- confirmed against a real sandbox response.
2. There is no custom AAD for the OTP seal. An earlier version reused the
   `sender || recipient` AAD from Turnkey's own JS client
   (`@turnkey/crypto`'s `hpkeEncrypt`), on the theory that Grid's
   embedded-wallet stack, being built on Turnkey, might mirror it. Grid's
   own client-keys guide shows the OTP bundle built through a plain
   `hpkeEncryptToGridBundle({plainTextBuf, targetKeyBuf})` helper with no
   `info`/`aad` parameters at all -- that custom AAD convention turned out
   to belong to a separate, legacy-only session-key-decrypt flow the same
   guide documents with its own explicit AAD, not to the OTP seal. This
   version uses HPKE's own empty defaults for both `info` and `aad`.

## What is not verified

`otpEncryptionTargetBundle` also carries a `dataSignature` proving the
target key came from Grid's enclave, verifiable against
`enclaveQuorumPublic`. This module does not verify that chain -- doing so
correctly needs Grid's real production quorum key and attestation format,
neither confirmed from a live sandbox response yet. Skipping it means
trusting the target key Grid hands back within the same authenticated
(Basic Auth) API call that requested it, which is the same trust boundary
every other call in this rail already relies on.
"""
from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass

from cryptography.hazmat.primitives import hashes, hmac
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

_CURVE = ec.SECP256R1()

# RFC 9180 base-mode constants for DHKEM(P-256, HKDF-SHA256) / HKDF-SHA256 /
# AES-256-GCM, copied byte-for-byte from `@turnkey/crypto`'s constants.js.
_HPKE_VERSION = b"HPKE-v1"
_SUITE_ID_KEM = bytes([75, 69, 77, 0, 16])  # "KEM" || kem_id(0x0010)
_SUITE_ID_HPKE = bytes([72, 80, 75, 69, 0, 16, 0, 1, 0, 2])  # "HPKE" || kem_id || kdf_id || aead_id
_LABEL_EAE_PRK = b"eae_prk"
_LABEL_SHARED_SECRET = b"shared_secret"
_LABEL_SECRET = b"secret"
_LABEL_PSK_ID_HASH = b"psk_id_hash"
_LABEL_INFO_HASH = b"info_hash"
_LABEL_KEY = b"key"
_LABEL_BASE_NONCE = b"base_nonce"
_MODE_BASE = bytes([0x00])


class TurnkeyStampError(Exception):
    """Raised for anything that stops a stamp or an HPKE seal being built."""


@dataclass(frozen=True)
class TurnkeyKeyPair:
    """A P-256 keypair in the hex encodings Grid's API expects: a raw
    32-byte private scalar, and a compressed (33-byte, `02`/`03`-prefixed)
    public point."""
    private_key_hex: str
    public_key_hex: str

    def _private_key(self) -> ec.EllipticCurvePrivateKey:
        return ec.derive_private_key(int(self.private_key_hex, 16), _CURVE)


def generate_keypair() -> TurnkeyKeyPair:
    private_key = ec.generate_private_key(_CURVE)
    private_hex = format(private_key.private_numbers().private_value, "064x")
    public_hex = private_key.public_key().public_bytes(
        Encoding.X962, PublicFormat.CompressedPoint,
    ).hex()
    return TurnkeyKeyPair(private_key_hex=private_hex, public_key_hex=public_hex)


def build_stamp(payload: str, keypair: TurnkeyKeyPair) -> str:
    """Builds the value of the `Grid-Wallet-Signature` header: an ECDSA-P256
    signature over `payload` taken byte-for-byte (never re-serialized),
    wrapped as `{"publicKey", "scheme", "signature"}` and base64url-encoded
    without padding -- exactly `@turnkey/api-key-stamper`'s `ApiKeyStamper.
    stamp()`, ported from its published source.
    """
    signature_der_hex = keypair._private_key().sign(
        payload.encode(), ec.ECDSA(hashes.SHA256()),
    ).hex()
    stamp = {
        "publicKey": keypair.public_key_hex,
        "scheme": "SIGNATURE_SCHEME_TK_API_P256",
        "signature": signature_der_hex,
    }
    stamp_json = json.dumps(stamp, separators=(",", ":"))
    base64_str = base64.b64encode(stamp_json.encode()).decode()
    return base64_str.replace("+", "-").replace("/", "_").rstrip("=")


def _hkdf_extract(salt: bytes, ikm: bytes) -> bytes:
    hasher = hmac.HMAC(salt, hashes.SHA256())
    hasher.update(ikm)
    return hasher.finalize()


def _hkdf_expand(prk: bytes, info: bytes, length: int) -> bytes:
    return HKDFExpand(algorithm=hashes.SHA256(), length=length, info=info).derive(prk)


def _labeled_extract(salt: bytes, label: bytes, ikm: bytes, suite_id: bytes) -> bytes:
    labeled_ikm = _HPKE_VERSION + suite_id + label + ikm
    return _hkdf_extract(salt, labeled_ikm)


def _labeled_expand(prk: bytes, label: bytes, info: bytes, length: int, suite_id: bytes) -> bytes:
    labeled_info = length.to_bytes(2, "big") + _HPKE_VERSION + suite_id + label + info
    return _hkdf_expand(prk, labeled_info, length)


def _kem_extract_and_expand(dh: bytes, kem_context: bytes) -> bytes:
    """RFC 9180 DHKEM's `ExtractAndExpand`: derives the KEM shared secret
    from the raw ECDH output."""
    eae_prk = _labeled_extract(b"", _LABEL_EAE_PRK, dh, _SUITE_ID_KEM)
    return _labeled_expand(eae_prk, _LABEL_SHARED_SECRET, kem_context, 32, _SUITE_ID_KEM)


def _key_schedule(shared_secret: bytes) -> tuple[bytes, bytes]:
    """RFC 9180's `KeySchedule` in base mode (no PSK, no application info):
    returns `(key, base_nonce)` for the AEAD. Computed from scratch rather
    than reusing any precomputed constant, so nothing here depends on
    matching another implementation's shortcuts -- only the spec itself.
    """
    psk_id_hash = _labeled_extract(b"", _LABEL_PSK_ID_HASH, b"", _SUITE_ID_HPKE)
    info_hash = _labeled_extract(b"", _LABEL_INFO_HASH, b"", _SUITE_ID_HPKE)
    key_schedule_context = _MODE_BASE + psk_id_hash + info_hash

    secret = _labeled_extract(shared_secret, _LABEL_SECRET, b"", _SUITE_ID_HPKE)
    key = _labeled_expand(secret, _LABEL_KEY, key_schedule_context, 32, _SUITE_ID_HPKE)
    base_nonce = _labeled_expand(secret, _LABEL_BASE_NONCE, key_schedule_context, 12, _SUITE_ID_HPKE)
    return key, base_nonce


def _load_public_key(uncompressed_or_compressed: bytes) -> ec.EllipticCurvePublicKey:
    return ec.EllipticCurvePublicKey.from_encoded_point(_CURVE, uncompressed_or_compressed)


def _uncompressed_bytes(public_key: ec.EllipticCurvePublicKey) -> bytes:
    return public_key.public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def _hpke_seal(plaintext: bytes, target_public_key_hex: str) -> tuple[str, bytes]:
    """RFC 9180 base-mode HPKE seal for Grid's OTP target bundle. Grid's own
    guide shows this built via a plain `hpkeEncryptToGridBundle({
    plainTextBuf, targetKeyBuf})` helper with no `info`/`aad` parameters
    exposed at all -- unlike a separate, legacy-only session-key-decrypt
    flow the same guide documents with an explicit custom AAD -- so this
    uses HPKE's own empty defaults for both rather than inventing either.
    Returns `(uncompressed_ephemeral_public_hex, ciphertext_bytes)`.
    """
    target_key = _load_public_key(bytes.fromhex(target_public_key_hex))

    ephemeral_private = ec.generate_private_key(_CURVE)
    ephemeral_public = ephemeral_private.public_key()
    ephemeral_uncompressed = _uncompressed_bytes(ephemeral_public)

    shared_point = ephemeral_private.exchange(ec.ECDH(), target_key)
    kem_context = ephemeral_uncompressed + _uncompressed_bytes(target_key)

    shared_secret = _kem_extract_and_expand(shared_point, kem_context)
    key, base_nonce = _key_schedule(shared_secret)

    ciphertext = AESGCM(key).encrypt(base_nonce, plaintext, None)
    return ephemeral_uncompressed.hex(), ciphertext


def _parse_otp_target_bundle(bundle: str) -> str:
    """Extracts the hex-encoded target public key from an
    `otpEncryptionTargetBundle`. The bundle wraps a hex-encoded JSON `data`
    field (plus a `dataSignature`/`enclaveQuorumPublic` this module does
    not verify -- see the module docstring); this tries strict JSON first
    and falls back to a lenient parse for the unquoted-key form Grid's own
    API docs show as an example, so a real sandbox response in either
    shape is handled without guessing further.
    """
    text = bundle.strip().strip("'").strip()
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = {}
        for part in text.strip("{}").split(","):
            if ":" not in part:
                continue
            key, _, value = part.partition(":")
            parsed[key.strip().strip('"')] = value.strip().strip('"')

    data_hex = parsed.get("data")
    if not data_hex:
        raise TurnkeyStampError(
            f"otpEncryptionTargetBundle has no 'data' field (keys seen: {list(parsed)})"
        )
    try:
        inner = json.loads(bytes.fromhex(data_hex).decode())
    except (ValueError, UnicodeDecodeError) as error:
        raise TurnkeyStampError(f"could not decode otpEncryptionTargetBundle.data: {error}") from error

    for key in ("targetPublicKey", "targetPublic", "publicKey", "target_public_key"):
        if key in inner:
            return inner[key]
    raise TurnkeyStampError(
        f"otpEncryptionTargetBundle.data has no recognized public-key field (keys seen: {list(inner)})"
    )


def seal_otp_bundle(otp_code: str, client_public_key_hex: str, target_bundle: str) -> dict:
    """Builds the `encryptedOtpBundle` value for `POST /auth/credentials/
    {id}/verify`: HPKE-seals `{"otp_code", "public_key"}` (the OTP and the
    client's new TEK public key) to the target key inside
    `otpEncryptionTargetBundle`.
    """
    target_public_key_hex = _parse_otp_target_bundle(target_bundle)
    plaintext = json.dumps({"otp_code": otp_code, "public_key": client_public_key_hex}).encode()
    encapped_public_hex, ciphertext = _hpke_seal(plaintext, target_public_key_hex)
    return {"encappedPublic": encapped_public_hex, "ciphertext": ciphertext.hex()}


def sandbox_otp_code() -> str:
    """Grid sandbox's fixed magic OTP -- the user "receives" this instead
    of a real email/SMS delivery. Overridable via env var only so tests
    can exercise a different value without touching the constant."""
    return os.environ.get("REGISTRY_GRID_SANDBOX_OTP", "000000")
