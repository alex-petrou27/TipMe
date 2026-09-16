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

# Optional. Only needed for self-service "Connect Instagram/TikTok"
# verification — see "Platform sign-in" below. Either pair can be left unset;
# that platform's /start endpoint then fails closed with a 503 instead of
# offering a sign-in it cannot complete.
export INSTAGRAM_CLIENT_ID=...
export INSTAGRAM_CLIENT_SECRET=...
export INSTAGRAM_REDIRECT_URI=https://your-registry-host/v1/oauth/instagram/callback
export TIKTOK_CLIENT_KEY=...
export TIKTOK_CLIENT_SECRET=...
export TIKTOK_REDIRECT_URI=https://your-registry-host/v1/oauth/tiktok/callback
export TIPME_APP_URL_SCHEME=tipme        # defaults to "tipme"; must match the app's CFBundleURLTypes

uvicorn tipme_registry.app:app --reload
pytest
```

## Endpoints

| Method | Path | Notes |
|---|---|---|
| `GET` | `/v1/creators/{platform}/{username}` | Signed lookup. The hot path. |
| `POST` | `/v1/creators` | Claim a handle (open) or change one (needs `X-Management-Token`). |
| `POST` | `/v1/creators/{platform}/{username}/verify` | Admin only — the manual bio-code path. |
| `DELETE` | `/v1/creators/{platform}/{username}` | Admin only. |
| `POST` | `/v1/oauth/{platform}/start` | Begins "Connect Instagram/TikTok". Returns an authorize URL. |
| `GET` | `/v1/oauth/{platform}/callback` | Instagram/TikTok redirect here, never the app. |
| `GET` | `/v1/oauth/session/{session_id}` | One-time collection of the callback's result. |
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

## Claiming versus changing

Claiming an **unclaimed** handle is open: there is no identity to check against
yet, so a fresh record is always `verified: false` and the app labels it.

Changing an **existing** record is not. The first claim returns a
`management_token`, required for any later change (the admin token also works).
Without this, anyone could re-register a registered creator's handle, point it
at their own wallet, and collect their tips — clearing the verified flag warns
users but does not stop the payment.

The token is returned **only** on first claim; re-issuing it on every update
would let anyone who can read one response take the record over. Records
predating management tokens fail closed and need an admin to change.

New claims are rate limited per client (`REGISTRY_REGISTRATIONS_PER_HOUR`,
default 10). The limiter is in-memory, and the client key comes from
`X-Forwarded-For` when present — that header is client-controlled, so this
throttles casual handle-squatting and is not a security control. A
multi-process deployment needs it in shared storage.

## Getting verified: platform sign-in, or a human

Registration is open: anyone can claim any handle. A new record is therefore
always `verified: false`, and the app labels it. Without that distinction,
registering `@charlidamelio` would be enough to collect her tips. Re-registering
a handle with a different wallet always clears verification too, so a hijacked
account cannot inherit a badge it did not earn.

Two ways to earn it back:

- **Platform sign-in** (`oauth.py`) — the creator authenticates directly with
  Instagram or TikTok. We exchange the resulting code server-side, read the
  username back from the platform's own "who am I" endpoint, and mark the
  record verified only if it matches the handle being claimed. This is
  self-service and immediate, and it is a strictly stronger proof than a bio
  code: signing in as `@someone` requires actually controlling `@someone`,
  which also means it can reclaim a handle someone else squatted first (see
  `test_oauth_verification_can_overwrite_a_squatted_handle`).

  It needs real platform apps registered before it does anything — see the
  env vars above. Two constraints that are platform limits, not something this
  code can route around:
  - **Instagram** OAuth login only exists for Business/Creator accounts (Meta
    retired it for personal accounts). A personal-account creator still needs
    the bio-code path below.
  - **TikTok** works for any account, but a new app is capped to its own
    registered sandbox testers until TikTok approves it for production use of
    `user.info.basic`.

- **Reading a bio code** (`POST /v1/creators/{platform}/{username}/verify`) —
  the fallback for personal Instagram accounts, or for either platform before
  its developer app is approved. No third-party API can read a profile bio, so
  a human checks the claim token and an admin flips the flag by hand.

## Platform sign-in flow

1. App calls `POST /v1/oauth/{platform}/start` with the handle and wallet
   details it wants to register (same shape as `POST /v1/creators`). The
   registry stores that as a pending claim keyed by a random `state` and
   returns Instagram/TikTok's `authorize_url`.
2. The app opens that URL in `ASWebAuthenticationSession`. The creator signs
   in and consents on the platform's own page — this service never sees their
   password.
3. The platform redirects the browser to `GET /v1/oauth/{platform}/callback`
   on **this service** (registered as the app's redirect URI), carrying a
   one-time `code`. We exchange it for an access token, fetch the platform's
   own username for that token, and compare it against the pending claim.
   Match: the handle is registered/updated and marked `verified`. No match,
   expired state, or a declined consent: nothing is written.
4. Either way, the callback finishes with a redirect to
   `{TIPME_APP_URL_SCHEME}://oauth-complete?...`, which
   `ASWebAuthenticationSession` intercepts and hands back to the app.
5. That redirect never carries the management token — a custom URL scheme is
   routed by the OS and a second app registering the same scheme could in
   principle intercept it. It carries only an opaque, single-use
   `session_id`; the app immediately exchanges that for the real values via a
   direct HTTPS call to `GET /v1/oauth/session/{session_id}`, which is deleted
   the moment it is read (or after five minutes, whichever comes first).

## Handle and address rules

`handles.py` and `lightning.py` deliberately mirror `CreatorHandle` and
`LightningAddress` in the iOS core. **They must stay in step.** If the server
accepts something the client will not, a creator can register a handle no sender
is able to look up, and neither side reports an error. Both sides have test
suites covering the same cases.

## Phase 2

Parked. Comment-triggered tips are out of scope for now; if they are ever picked
back up, the webhook receiver belongs here — it is HTTP, server-side, and next
to the records that gate opt-in. Read `../docs/PHASE2.md` first: Meta App Review
is the lesser obstacle. The larger one is that a server cannot hold a
non-custodial sender's keys, so a server-side trigger cannot itself move a
sender's money.
