# TipMe creator registry

Answers one question for the app: given a TikTok or Instagram handle, where do
this creator's tips go?

The link is made once, when the creator onboards, and persists until deleted —
senders never re-establish it per payment.

## Why this service exists

Parsing `@charlidamelio` out of a shared URL is the easy half. At that moment
the app holds a username string and nothing else; to pay, it needs an LNURL-pay
address. No wallet SDK can bridge that — Breez can pay any Lightning address but
has no idea which one belongs to which TikTok handle. Something has to hold the
mapping, and this is it.

## Running it

```bash
pip install -e ".[dev]"

# Generate a signing keypair. Private half stays here; public half is baked
# into the iOS app as TIPME_REGISTRY_PUBLIC_KEY.
python -m tipme_registry.keygen

export REGISTRY_SIGNING_PRIVATE_KEY=...
export REGISTRY_DATABASE_PATH=tipme_registry.sqlite3
export REGISTRY_ADMIN_TOKEN=...          # required for verify/delete

uvicorn tipme_registry.app:app --reload
pytest
```

## Endpoints

| Method | Path | Notes |
|---|---|---|
| `GET` | `/v1/creators/{platform}/{username}` | Signed lookup. The hot path. |
| `POST` | `/v1/creators` | Creator onboarding. Open; always unverified. |
| `POST` | `/v1/creators/{platform}/{username}/verify` | Admin only. |
| `DELETE` | `/v1/creators/{platform}/{username}` | Admin only. |
| `GET` | `/v1/public-key` | Setup convenience only — see below. |
| `GET` | `/health` | |

## Response signing

Every lookup returns `{"payload": base64, "signature": base64}`, Ed25519-signed.
The client verifies before any field reaches its payment path.

This is not belt-and-braces over TLS. TLS authenticates the *connection* to
whoever holds a certificate for the hostname; it does not authenticate the
*record*. A compromised CDN edge or hijacked DNS entry could otherwise swap a
creator's address for an attacker's, silently, for every sender in the app.

`GET /v1/public-key` exists for setup convenience only. The app must ship with
the key baked in — fetching it at runtime from the same server whose responses
it authenticates would defeat the entire point.

Timestamps are emitted as RFC3339 with **no fractional seconds**, because
Swift's `JSONDecoder.dateDecodingStrategy = .iso8601` uses `ISO8601DateFormatter`
with `.withInternetDateTime` only and rejects them outright. There is a test
pinning this.

## Verification is manual, and why

Registration is open: anyone can claim any handle. A new record is therefore
always `verified: false`, and the app labels it. Without that distinction,
registering `@charlidamelio` would be enough to collect her tips.

Proving that whoever registered `@someone` really is `@someone` needs either:

- **Reading their profile bio** for a claim token — no third-party API exists
  for either platform, and scraping breaches both sets of terms; or
- **Platform OAuth** — TikTok Login Kit or Instagram Graph API, both of which
  require App Review.

Until one of those is in place, registration issues a claim token, a human
checks it, and an admin flips the flag. Re-registering a handle with a different
wallet clears verification, so a hijacked account cannot inherit a badge it did
not earn.

## Handle and address rules

`handles.py` and `lightning.py` deliberately mirror `CreatorHandle` and
`LightningAddress` in the iOS core. **They must stay in step.** If the server
accepts something the client will not, a creator can register a handle no sender
is able to look up, and neither side reports an error. Both sides have test
suites covering the same cases.

## Phase 2

The Instagram comment webhook receiver belongs here — it is HTTP, server-side,
and next to the records that gate opt-in. Read `../docs/PHASE2.md` first: the
Meta App Review is the lesser obstacle. The larger one is that a server cannot
hold a non-custodial sender's keys, so a server-side trigger cannot itself move
a sender's money.
