# TipMe

Lightning micro-tipping triggered from the iOS share sheet. A viewer shares a
TikTok or Instagram post, taps **Tip via TipMe**, and the creator is paid
directly — without leaving their feed for more than a few seconds.

In practice that is *Share → More → Tip via TipMe*, because third-party apps
cannot appear in TikTok's or Instagram's own share row. See
[Where TipMe actually appears](#where-tipme-actually-appears) — it is the single
most important thing to understand about this product's reach.

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
App/Shared/TipSheet/   The tip sheet UI, used by both surfaces below
App/TipMe/             Host app: onboarding, funding, paste-to-tip, creator setup
App/TipMeShare/        The share extension
Registry/              Creator registry service (Python/FastAPI)
docs/                  Share-extension testing, Phase 2, security model
```

`TipMeCore` is deliberately free of UI and SDK imports so the app, the
extension, and any future Phase 2 trigger all drive the identical logic.
`App/Shared/TipSheet` is shared for the same reason at the UI layer: the
share-sheet path and the paste path present the same sheet, so they cannot
drift apart.

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

# 3b. Static checks that do not need a Swift toolchain at all
python3 Scripts/swift-sanity.py

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

## Where TipMe actually appears

Worth being precise about, because it is not where people first look and it
sets the real interaction cost.

When you tap Share on a TikTok video or an Instagram post, the pop-up you get
is **TikTok's or Instagram's own UI**: Repost, SMS, WhatsApp, Messenger,
Telegram, Email, Copy link, Add to story. Those slots are hardcoded first-party
integrations. There is no API, no registration, and no commercial route for a
third-party app to appear among them. **TipMe cannot be in that row.**

What we get is the **More** / **Share to…** button at the end of it, which is
what opens the iOS system share sheet. TipMe appears in the app row there.

So the honest path is:

> Share → **More** → **Tip via TipMe**

and on first use iOS hides new extensions at the end of that row, so a new user
must tap **More → Edit**, enable TipMe, and drag it to the top. After that it
sits near the front and the flow is two taps.

That is 2–3 taps rather than the one the original brief implied. The in-app
`HowToTipView` walks users through it, including the first-run enable step —
without it, a new user taps Share, does not see TipMe, and reasonably concludes
the app is broken.

### The clipboard companion

**Copy link** *is* in that prominent first row on both apps. TipMe cannot be in
the row, but it can be what the user does next: copy the link, open TipMe, and
the tip is already waiting on the home screen.

This is deliberately built to avoid the obvious privacy problem. Reading
`UIPasteboard.general.string` triggers the system "TipMe pasted from TikTok"
banner and hands over the content whether we needed it or not — bad behaviour
for an app that opens straight onto a wallet. Instead:

1. `detectPatterns(for: [.probableWebURL])` answers only *"is there probably a
   link?"* — no banner, no content.
2. The card appears only if the answer is yes.
3. The content arrives solely through a system `PasteButton` the user taps.

If the pasted link is not one of ours, the card says so rather than opening a
tip sheet that immediately dead-ends.

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
| TikTok post, share directly to TipMe | Amount picker, creator named |
| TikTok "Copy link" → paste → share | Same, via a `vm.tiktok.com` redirect |
| TikTok share sheet → **More** → TipMe | Same — this is the common real path |
| TikTok profile | Amount picker |
| Instagram profile | Amount picker |
| Instagram story | Amount picker |
| Instagram Reel — share sheet | Identified from "Reel from @user" title |
| Instagram Reel — **copied link** | Manual entry (no title on the clipboard) |
| A news article | Manual entry fallback |
| Tip twice in quick succession, then a third | Third is rate-limited |
| **First run:** Share → More → Edit → enable TipMe | Appears in the row afterwards |
| **Copy link** in TikTok, then open TipMe | Paste card on the home screen |
| Copy an unrelated link, then open TipMe | Card says it isn't recognised |

TikTok short links are the path most worth walking on a device, because it is
what TikTok's own share sheet produces and it is the one step that depends on a
live network round trip.

### Memory

The extension's working directory is the App Group container that the host app
has already synced, so it performs an incremental sync rather than a cold one.
If you see jetsam terminations, the host app has probably not run recently —
see `docs/SHARE_EXTENSION.md`.

---

## Platform coverage

| Share | Status |
|---|---|
| TikTok post (`/@user/video/…`, `/photo/…`) | Handle from URL |
| TikTok short link (`vm.`/`vt.tiktok.com`, `/t/…`) | Handle from URL, after redirect |
| TikTok profile | Handle from URL |
| Instagram profile | Handle from URL |
| Instagram story (`/stories/<user>/…`) | Handle from URL |
| Instagram post from a profile grid (`/<user>/p/…`) | Handle from URL |
| **Instagram Reel (`/reel/<code>/`)** | **Handle from share title** |
| **Instagram post (`/p/<code>/`)** | **Handle from share title** |

### Two places the creator's name can hide

The obvious one is the URL. TikTok puts the handle in the path
(`tiktok.com/@user/video/123`), and short links — which is what TikTok's own
share sheet actually emits — resolve to the same through unauthenticated
redirects.

The less obvious one, and the reason Instagram Reels are supported rather than
deferred: **the handle is in the share sheet's title.** An Instagram Reel URL is
shortcode-keyed and names nobody, but when you share a Reel the system share
sheet header reads:

> **Reel from @natgeo**

That string arrives in the extension as the item's `attributedTitle` or inside
its `LPLinkMetadata`, so a Reel is identifiable with no API access at all. It
was only unreachable while we were looking exclusively at the URL.

`ShareTitleParser` handles the attribution forms ("Reel from @user", "Post by
@user", "@user on Instagram") and is deliberately conservative, because a title
is prose rather than a structured field:

- An explicit attribution wins even when other accounts are mentioned —
  "Reel from @natgeo ft. @nasa" is about `@natgeo`.
- A **single** unambiguous mention is accepted.
- **Several distinct mentions yield nothing.** A caption that tags other
  accounts must not be guessed at; paying the wrong creator is unrecoverable,
  so the user gets manual entry instead.
- Emails are not mentions. Without a lookbehind on the `@`,
  `support@instagram.com` produces a "creator" called `instagram.com`.

The URL always wins when both sources name someone, since the platform put the
handle there deliberately.

**The paste path is weaker here.** A copied link arrives without the share
sheet's header, so copying an Instagram Reel link still falls back to manual
entry, while *sharing* the same Reel identifies it. Worth knowing when choosing
which flow to promote.

## The creator side

A sender can only tip someone who has told TipMe where their money goes.
**Get tipped** in the host app (`CreatorSetupView`) links a handle to a wallet,
once, permanently until the creator changes it.

Any Lightning address works — Alby, Strike, Wallet of Satoshi, Coinos, a
self-hosted node. TipMe never holds the funds.

### The address is verified before it is stored

`LightningAddressVerifier` resolves the LNURL-pay endpoint and checks the
response really is a `payRequest` with an https callback and a sane sendable
range, before registration is allowed.

This is not a nicety. Consider a creator who registers `charli@getably.com`
instead of `charli@getalby.com`. Nothing rejects it, senders share her videos,
and every tip fails — or lands with whoever owns the typo'd domain. She finds
out weeks later, wondering why she has never been paid. One HTTP request turns
an invisible, slow, expensive failure into an immediate legible one.

### Claiming versus changing

**Claiming an unclaimed handle is open.** There is no identity to check against
yet, which is why a fresh record is always `verified: false` and the confirm
screen says so.

**Changing an existing record is not open.** The first claim issues a
`management_token`, required for any later change. Without that distinction,
anyone could re-register a registered creator's handle, point it at their own
wallet, and collect that creator's tips — clearing the verified flag would warn
users but would not stop the payment.

The app stores that token in the keychain (`CreatorTokenStore`, same protection
class as the wallet key). Showing it once and hoping the creator writes it down
would mean most of them silently lose the ability to ever move wallets.

New claims are also rate limited per client, because handle-squatting is
otherwise cheap: a script could claim every popular handle before their owners
do and point them all at one wallet.

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

## Policy notes

Nothing here blocks current work; recorded so it is not rediscovered late.

- **App Store Guideline 3.1.1 / crypto wallets** requires an *organization*
  developer enrolment rather than an individual one. Confirmed as available and
  not a current focus — it becomes load-bearing only at submission.
- **Handle verification is manual.** Proving that whoever registered `@someone`
  really is `@someone` needs either a profile read (no third-party API for
  either platform; scraping breaches both sets of terms) or platform OAuth
  (TikTok Login Kit, Instagram Graph API — both require App Review). Until then
  records are marked unverified and the confirm screen says so. This is the one
  item on this list with a live product consequence.
- **Instagram oEmbed** is no longer needed for share-sheet identification —
  the title carries the handle. It would only help the copied-link path, where
  no title is available.

## Build and verification status

Honest accounting of what has and has not been executed.

**Verified by running it:**

- **TipMeCore compiles and its tests run**, on a macOS GitHub Actions runner
  (`.github/workflows/ci.yml`). This is new — the Swift had never been through
  a compiler. 145 tests execute.

- Registry service — 59 tests pass, plus a live end-to-end smoke test
  (registration, handle normalisation, signed lookup, signature verification,
  Swift-compatible timestamp format).
- The URL parse rules — a 39-case fixture corpus and 7 hostile URLs were
  executed against an oracle implementing the same rules, including three
  lookalike-host cases (`tiktok.com.evil.co`, `www.tiktok.com.attacker.io`,
  `faketiktok.com`). TikTok coverage includes tracking parameters, trailing
  slashes, photo posts, live links, profile variants and all three short-link
  forms.
- `Scripts/make-xcconfig.sh` — run against `.env.example`.
- `project.yml` — validated as well-formed.

- `Scripts/swift-sanity.py` — static checks over all 59 Swift files: delimiter
  balance, duplicate non-private type declarations, and references to types
  that are neither declared nor known framework types. It is not a compiler,
  but it catches renames left half-applied and helpers referenced but never
  written. Currently clean.

**Not yet verified:** the app and share-extension targets. They compile only in
the `app` CI job, which additionally resolves the Breez SDK. Expect real work
there: `BreezPaymentBackend` was written against the documented Nodeless API
without a compiler, and the pinned version was corrected from a guessed 0.6.6 to
the real 0.12.4, so those call sites are the least trustworthy code in the
repository. Everything they depend on in `TipMeCore` is now compiler-verified.

This repository is assembled in a Linux container where `download.swift.org` is
blocked by egress policy, so there is no local Swift toolchain — CI is the
compiler.

## Not built yet

- **Android.** The `PaymentBackend`/`TipFlow` split is designed so an Android
  port reimplements the UI and the wallet binding, not the rules.
- **Identifying a copied Instagram Reel link** — the clipboard carries no
  title, so that path still falls back to manual entry.
- **Comment-triggered tips** — parked. See `docs/PHASE2.md` for why this one is
  harder than it looks even with Meta approval.
- **Phase 2** App Clip and Instant App — designed for, not built.
- **Automated handle verification** — see *Policy notes*.
