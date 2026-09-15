# Security model

The gates here are hard gates. Every one of them lives in `TipMeCore` and is
enforced on the payment path — none is advisory, and none is implemented in the
UI where a different entry point could skip it.

## The authorization gate

`PaymentEngine.execute` accepts exactly one type: `AuthorizedIntent`. That
type's only initialiser is `private` to `AuthorizationGate.swift`, so the only
code in the program that can produce one is `AuthorizationGate.authorize`,
which does not return unless a live biometric check has just succeeded.

Properties this buys:

- **No automated caller can mint one.** Not a model response, not a deep link,
  not a push payload, not an assistant layer added in a year's time. The worst
  any of them can do is construct a `PaymentIntent` — a *description* of a
  payment — and ask the gate to authorise it, which puts a system biometric
  prompt in front of a human.
- **Single use.** Each token carries a nonce the engine burns on execution, so
  a token cannot be replayed within its lifetime.
- **Short lived.** 60 seconds. It exists to cover the moment between Face ID
  succeeding and the payment leaving, not to sit around and be spent later.
- **Enforced by the compiler**, not by review. If a future change adds a public
  or `@testable` initialiser to `AuthorizedIntent`, this guarantee is gone; the
  type carries a comment saying so, and the test suite deliberately goes through
  `gate.authorize` rather than constructing one.

The biometric prompt names the creator and the exact total, so the system sheet
itself states what is being approved. The user does not have to trust that our
screen and our payment agree.

## Send caps

Per tip, rolling 24 hours, rolling 7 days. Denominated in a single fiat
currency, which matters for two reasons: a per-asset cap is bypassed by
switching asset, and a sats-denominated cap silently changes meaning every time
the Bitcoin price moves.

A cap that cannot be evaluated — a request in an unexpected currency — is
**refused**, never waived.

## Rate limits

Sliding window, two of them:

- **Per creator** (default 3 per 10 minutes) catches a shaky thumb firing a
  payment twice.
- **Global** (default 20 per hour) catches the pattern a drained wallet actually
  looks like: many tips to many different creators, none of which trips a
  per-creator limit.

An attempt is recorded *before* the money moves, so a payment that fails still
consumes a slot. Otherwise a caller could retry a failing payment indefinitely
and never trip the limiter.

## Re-evaluation at spend time

Every gate is checked again inside `PaymentEngine.execute`, not only when the
confirm screen was drawn. The screen may have been sitting open; the exchange
rate may have moved; the user may have tipped from the host app in the
meantime. Checking only at render time would make all of these advisory.

The rate check is the sharpest example. The sheet renders "£1.00 tip + £0.03
fee", the user leaves it open, the price moves, and Face ID then authorises a
sat amount that no longer matches the pounds they agreed to. The engine refuses
a quote whose rate is older than 120 seconds and sends the user back to a fresh
one.

## Audit log

JSON Lines, one object per line, in the shared App Group container.

- **One object per line** because a process killed mid-write costs the last
  line and nothing else. A single JSON array would be unreadable after any
  interrupted write, and this code runs in an extension the OS can kill
  mid-payment.
- **Every attempt and outcome**, including refusals. A payment blocked by a cap
  is as visible in the log as one that succeeded.
- **Redacted destinations** (`ch***@getalby.com`). The log outlives the payment
  and must not become a record of who tips whom.
- **Bounded** by single-generation rotation at 5 MB, on a device where nothing
  will ever clean it up.
- Written with `.completeUntilFirstUserAuthentication` file protection.

## Registry response signing

The registry's answer *is* the destination of the money, so every response is
Ed25519-signed and verified before a single field reaches the payment path.

TLS is not sufficient on its own: it authenticates the connection to whoever
currently holds a certificate for the hostname, which is not the same as
authenticating the record. A compromised CDN edge, a mis-issued certificate or
a hijacked DNS entry could otherwise swap a creator's address for an attacker's,
silently, for every sender in the app.

Three checks, all of which matter:

1. **Signature** against a public key baked into the app. Baked in, not fetched
   — a key fetched from the server whose responses it authenticates proves
   nothing.
2. **Freshness** (`signed_at`, default 300 s), so a captured response cannot be
   replayed after a creator has moved wallet.
3. **That the record answers the question asked.** A correctly-signed record for
   a *different* creator is still a valid signature; without this check a
   registry bug or a swapped response pays the wrong person.

## Input validation

`CreatorHandle` and `LightningAddress` both validate strictly at construction,
because both end up inside URLs that are fetched and then paid.

- Host matching is against an exact allow-list. `tiktok.com.evil.co` is not
  TikTok — a `hasSuffix("tiktok.com")` check would let it through.
- Reserved path segments (`accounts`, `explore`, `p`, `discover`…) are not
  creators. Otherwise sharing an Instagram login URL would "identify" a creator
  called `accounts`.
- `..`, non-ASCII, over-length and empty handles are rejected outright.
- Short-link redirects are capped, time-limited, and every hop must stay on a
  host we recognise — an open redirect off the platform would otherwise walk us
  somewhere else entirely before we parsed a "handle" out of it.

## Money arithmetic

Integer minor units throughout, with overflow-checked operations. No floating
point anywhere on the payment path: `0.1 + 0.2` problems become real money
problems. Adding amounts of different assets traps rather than coercing.

## Creator records are write-protected after first claim

`POST /v1/creators` upserts, which made an obvious attack possible in an
earlier revision: re-register a registered creator's handle pointing at your
own wallet and collect their tips. Clearing the `verified` flag warned users
but did not stop the payment.

Now the first claim issues a `management_token`, and changing an existing
record requires it (or the admin token). Claiming an *unclaimed* handle stays
open, because there is no identity to check against yet — that is what the
unverified badge is for.

Two supporting details:

- The token is issued **once**. Re-issuing it on every update would let anyone
  who can read a single response take the record over.
- A record predating management tokens **fails closed**: it cannot be changed
  anonymously. For a payment destination that is the only safe default.

New claims are rate limited per client (default 10/hour). The limiter is
in-memory and the client key comes from `X-Forwarded-For` when present, which
is client-controlled — it throttles casual handle-squatting and is explicitly
not a security control. A multi-process deployment needs it moved to shared
storage, or the effective limit is the configured limit times the worker count.

## Lightning addresses are verified before they are stored

`LightningAddressVerifier` resolves the LNURL-pay endpoint at registration and
rejects anything that is not a `payRequest` with an https callback and a
consistent sendable range. An http callback is refused specifically because it
could be rewritten in flight to return an attacker's invoice.

## Recovery phrases are checked, not just acknowledged

Onboarding asks the user to pick three specific words back out of their phrase
before the wallet is considered set up, with decoys drawn from the same phrase
so writing the words down in the wrong order is also caught. A checkbox saying
"I've written these down" is not a backup, and this is the one irreversible
moment in the app — a user who taps past it has funds that nobody, including
us, can ever recover, and will not find out until they need them.

## What is deliberately *not* protected

- **A user with an unlocked phone and the passcode** can spend up to the caps.
  That is the intended threat model for a tipping app; anything stronger makes
  a two-second interaction impossible.
- **Unverified handles.** Anyone can register any handle. The record carries a
  `verified` flag, the confirm screen warns when it is false, and verification
  is admin-only — but until platform OAuth is available (see `PHASE2.md`), an
  unverified record is a claim rather than a fact.
