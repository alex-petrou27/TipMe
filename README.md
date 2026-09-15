# TipMe

Lightning micro-tipping triggered from the iOS share sheet. A viewer shares a
TikTok or Instagram post, taps **Tip via TipMe**, and the creator is paid
directly — without leaving their feed for more than a couple of seconds.

Non-custodial: TipMe never holds a balance. Every tip settles from the sender's
own on-device wallet to the creator's own Lightning address.

---

## Why native iOS

The share extension is the entire product, so the architecture was chosen by
what survives inside one.

An iOS share extension (`com.apple.share-services`) renders as a sheet over the
host app with no app switch — exactly the interaction the product needs. But it
runs under a hard jetsam memory cap far tighter than an app's, cannot call
`UIApplication.open`, and is killed without ceremony if it is slow or greedy.

Cross-platform frameworks do not survive that well. In Flutter or React Native
the iOS extension target must still be written in Swift; the common packages
(`receive_sharing_intent`, `share_handler`) work by forwarding the payload to
the *main app*, which is a full app switch — the exact UX this product rules
out. Booting a Flutter engine or a JS runtime inside the extension to avoid
that costs hundreds of milliseconds of cold start and a large share of the
memory budget. Either way the payment path ends up implemented twice.

Android is the easy side — an `ACTION_SEND` intent filter on a translucent
activity, with no meaningful resource constraints — and so was not the
deciding factor. It is not in this repository; see *Not built yet* below.

## Why Breez SDK — Nodeless

Self-custodial with no node, channel or liquidity management to run; LNURL-pay
and fiat rates built in; Liquid USDT alongside Bitcoin, which is what makes
sender-asset/receiver-asset conversion possible at all. Breez Native
(Greenlight) would mean per-user node provisioning, and `ldk-node` would put
channel management on us — both out of scope for a send-only tipping app.

The `PaymentBackend` protocol keeps this swappable. The obvious second backend
is NWC (NIP-47), where the user links a wallet they already run: near-zero
memory in the extension and no funding step at all, at the cost of being
unusable for anyone without a Lightning wallet already.

---

## Layout

```
Sources/TipMeCore/     Foundation-only core. No UIKit, no SwiftUI, no SDK.
  Parsing/             TikTok + Instagram URL handling, short-link resolution
  Money/               Integer-only amounts, fee policy, exchange rates
  Directory/           Handle -> wallet lookup, signed registry client
  Payments/            PaymentBackend protocol, settlement routes, the engine
  Security/            Send caps, rate limits, audit log, authorization gate
  Flow/                The share-sheet sequence, start to receipt
Tests/TipMeCoreTests/  Including a fixture corpus of real share URLs
App/TipMe/             Host app: onboarding, funding, settings, activity
App/TipMeShare/        The share extension
Registry/              Creator registry service (Python/FastAPI)
docs/                  Share-extension testing, Phase 2, security model
```

`TipMeCore` is deliberately free of UI and SDK imports so the app, the
extension, and any future Phase 2 trigger all drive the identical logic.

---

## Local dev setup

**Requires** macOS with Xcode 15+, an Apple Developer account, and a physical
iOS device. See *Testing the share extension* for why the simulator is not
enough.

```bash
# 1. Configuration
cp .env.example .env
$EDITOR .env                  # fill in the values described below
./Scripts/make-xcconfig.sh    # generates Config/Secrets.xcconfig from .env

# 2. Project
brew install xcodegen
xcodegen generate             # produces TipMe.xcodeproj

# 3. Core tests (no Xcode needed)
swift test

# 4. Registry service
cd Registry
pip install -e ".[dev]"
python -m tipme_registry.keygen   # put the two values in .env
pytest
uvicorn tipme_registry.app:app --reload
```

The project file is generated rather than committed, so target membership,
entitlements and extension embedding cannot drift through merge conflicts in a
10,000-line `pbxproj`.

### Breez SDK setup

1. Request an API key at <https://breez.technology/request-api-key/> (free,
   issued per app) and put it in `BREEZ_API_KEY`.
2. Leave `BREEZ_NETWORK=testnet` until you are deliberately testing with real
   money. Testnet Liquid funds come from a Liquid testnet faucet.
3. The SDK version is pinned exactly in `project.yml`. Breez has changed
   request/response shapes across minor versions, so re-check the call sites in
   `App/TipMe/Wallet/BreezPaymentBackend.swift` when upgrading — a mismatch
   there is a payment bug, not a build error.

### App Group and keychain group

`TIPME_APP_GROUP` and `TIPME_KEYCHAIN_ACCESS_GROUP` must match the entitlements
on **both** targets and must be registered on your developer account. A
mismatch does not fail the build; it fails at runtime, as an extension that
cannot find a wallet the user can plainly see in the app. This is the single
most common setup mistake on this project.

---

## Testing the share extension

**The OS share sheet integration cannot be meaningfully tested in the
simulator.** The simulator has no TikTok or Instagram app to share *from*, no
Face ID hardware (only a simulated "matching face" menu action), and its share
sheet does not reproduce the real extension lifecycle or memory pressure.

On a real device:

1. Build and run the **TipMe** scheme once, to the device. Complete onboarding
   so a wallet exists in the keychain, and add testnet funds via **Add funds**.
   The extension refuses to run without a wallet, by design.
2. In Xcode, switch the run destination to the **TipMeShare** scheme. Xcode will
   ask which app to launch — pick TikTok, Instagram, or Safari. This attaches
   the debugger to the extension when it is invoked.
3. In the host app, share a post and choose **Tip via TipMe**. If it is missing
   from the row, tap **More** and enable it.
4. Breakpoints and `os_log` work normally once attached. If the sheet
   disappears instantly, the extension crashed — check the device console for a
   jetsam (memory) termination rather than a Swift crash.

Useful cases to walk through, all of which the core tests already cover at the
logic level:

| Share | Expected |
|---|---|
| TikTok post by a registered creator | Amount picker, creator named |
| TikTok "Copy link" → Safari → share | Same, via a `vm.tiktok.com` redirect |
| Instagram Reel (`/reel/<code>/`) | Manual entry, with the honest explanation |
| Instagram post from a profile grid | Amount picker — that URL carries the handle |
| A news article | Manual entry fallback |
| Tip twice in quick succession, then a third | Third is rate-limited |

### Memory

The extension's working directory is the App Group container that the host app
has already synced, so it performs an incremental sync rather than a cold one.
If you see jetsam terminations, the host app has probably not run recently —
see `docs/SHARE_EXTENSION.md`.

---

## The Instagram constraint

TikTok URLs contain the handle (`tiktok.com/@user/video/123`), and short links
resolve through one unauthenticated redirect. Instagram post URLs do not:
`/p/<shortcode>/` and `/reel/<shortcode>/` are keyed by shortcode with no
username anywhere in them, and there is **no unauthenticated way to map one to
the other** — the web page is behind a login wall and the official oEmbed
endpoint requires an app token gated behind Meta App Review.

So Instagram parity is partial by necessity, not by omission:

- **Parsed:** `/<user>/p/<code>/`, `/<user>/reel/<code>/`, `/stories/<user>/…`,
  profile links.
- **Falls back to manual entry:** `/p/<code>/`, `/reel/<code>/`, `/share/…`.

The fallback explains why, rather than showing a generic failure. Scraping the
profile page would breach both platforms' terms and break on the login wall, so
it is not implemented.

---

## Fees

Sender-side only, added on top. The creator always receives the full tip amount.

Because LNURL-pay has no split primitive, collecting a fee while guaranteeing
the creator receives 100% requires **two payments**: the tip, then the fee to
TipMe's own address. Ordering is load-bearing — if only one can land it must be
the creator's. A failed fee collection is recorded in the audit log and is not
surfaced as a failed tip, because the creator *was* paid.

Everything is configurable (`TIPME_FEE_BASIS_POINTS` and the per-asset rules in
`FeePolicy`), including a waiver below which no fee is charged — under roughly
1,000 sats a 3% fee is a handful of sats and routing costs more than we collect.

---

## Security model

Summarised here, detailed in `docs/SECURITY.md`.

- **Send caps** (per tip, rolling day, rolling week), denominated in one fiat
  currency so switching asset cannot bypass them.
- **Rate limits**, per creator and global, over a sliding window.
- Both are **re-evaluated at spend time**, not only when the confirm screen
  renders — the sheet may have sat open, the rate may have moved, the user may
  have tipped from the app in the meantime.
- Both live in the **shared App Group**, so the app and the extension count
  against one ledger rather than two.
- **JSON-lines audit log** of every attempt and outcome, including refusals.
  One object per line, so a process killed mid-write costs the last line and
  nothing else. Destinations are redacted; the log must not become a record of
  who tips whom.
- **Registry responses are Ed25519-signed** and verified before any field
  reaches the payment path. The registry's answer *is* the destination of the
  money, and TLS authenticates the connection rather than the record.

### No AI layer can move funds

`PaymentEngine.execute` accepts only an `AuthorizedIntent`, whose sole
initialiser is `private` to `AuthorizationGate.swift`. The only code that can
reach it is the gate, which does not return one unless a live biometric check
has just succeeded — and the token it mints is single-use and expires in 60
seconds.

The result is enforced by the compiler rather than by reviewer vigilance: there
is no expressible path from a text input, a model response, a URL, a push
payload, or any assistant layer added later to a spend. The worst such a layer
could ever do is *propose* a payment that a human must then physically approve.
Even the test suite cannot construct an `AuthorizedIntent` directly.

---

## Policy risks

These can block or delay shipping regardless of the code.

- **App Store Guideline 3.1.1 / crypto wallets.** Wallet apps must be published
  by a developer enrolled as an **organization**, not an individual. If the
  TipMe developer account is an individual enrolment, iOS ships nowhere. Worth
  confirming before further investment.
- **Handle verification is manual.** Proving that whoever registered `@someone`
  really is `@someone` needs either a profile read (no third-party API exists
  for either platform; scraping breaches both sets of terms) or platform OAuth
  (TikTok Login Kit, Instagram Graph API — both require App Review). Until
  then, records are marked unverified and the confirm screen says so.
- **Phase 2 App Clip** review is discretionary and App Clips have their own
  size and capability limits.
- **Phase 2 Instagram comment triggers** require a Business/Creator account,
  Graph API OAuth, and App Review for comment-webhook permissions. There is no
  TikTok equivalent. See `docs/PHASE2.md`, which also covers the deeper problem:
  a server cannot hold a non-custodial sender's keys.

---

## Build and verification status

Honest accounting of what has and has not been executed.

**Verified by running it:**

- Registry service — 52 tests pass, plus a live end-to-end smoke test
  (registration, handle normalisation, signed lookup, signature verification,
  Swift-compatible timestamp format).
- The URL parse rules — the 26-case fixture corpus and 5 hostile URLs were
  executed against an oracle implementing the same rules, including the
  lookalike-host case (`tiktok.com.evil.co`).
- `Scripts/make-xcconfig.sh` — run against `.env.example`.
- `project.yml` — validated as well-formed.

**Not compiled:** the Swift. This repository was assembled in a Linux container
where `download.swift.org` is blocked by egress policy, so no Swift toolchain
could be installed and no Xcode exists. The Swift sources and XCTest suites have
not been through a compiler. Expect to fix ordinary compile errors on first
build — particularly around the Breez SDK call sites, which are written against
the documented Nodeless API but were not type-checked against the pinned
version. The logic they express is what the tests describe.

## Not built yet

- **Android.** The `PaymentBackend`/`TipFlow` split is designed so an Android
  port reimplements the UI and the wallet binding, not the rules.
- **Phase 2** App Clip, Instant App, and Instagram comment triggers — designed
  for, not built. See `docs/PHASE2.md`.
- **Automated handle verification** — see *Policy risks*.
