# Phase 2 — designed for, not built

Status: **parked.** Nothing here is implemented, and comment-triggered tips are
explicitly out of scope for now — current work is TikTok plus Instagram profiles
and stories.

This document is kept because the analysis below is the expensive part, and
because one of its conclusions should inform any later decision to pick
comment triggers back up: the obstacle is not Meta's API, it is custody.

## What Phase 1 already provides

`TipMeCore` has no UIKit, no SwiftUI, and no wallet SDK import. `PaymentEngine`
takes a `PaymentBackend` protocol and an `AuthorizedIntent`, and knows nothing
about where either came from. An App Clip, an Instant App, or a server-side
trigger can drive the identical engine without a rewrite — which was the
explicit Phase 1 requirement.

That holds for App Clips. It does **not** fully hold for server-side triggers,
for a reason worth being clear about now rather than at implementation time.

---

## Obstacle 1: a server cannot spend a non-custodial sender's money

This is the deeper of the two problems and it is architectural, not a matter of
API access. It is the reason to be wary of comment triggers even in a world
where Meta approves the integration tomorrow.

Comment-triggered tips mean: someone comments `@tipme send 50 sats`, a webhook
fires on our server, and a payment happens. But the sender's keys live in the
keychain on the sender's phone, under `WhenUnlockedThisDeviceOnly`. The server
has no access to them — that is the entire point of being non-custodial.

So a server-side trigger can do exactly one of:

1. **Become custodial** for a comment-tipping float. This contradicts the
   product's central claim, changes the regulatory position entirely
   (money transmission, KYC), and is a different company.
2. **Push a notification to the sender's device**, which wakes the app and
   presents the same biometric confirm. Still non-custodial, still honest — but
   it is no longer "comment and it's done", it is "comment, then approve on your
   phone". Slower than the share-sheet flow this product already has.
3. **Hold a delegated spending authority** — an NWC connection string, or a
   pre-signed budget the user grants to a server-held key. Genuinely
   non-custodial in the sense that the user can revoke it, but it creates a
   standing authority to spend the user's money without a per-payment human
   check. That directly contradicts the security property Phase 1 is built
   around, and would require its own caps, its own audit trail, and a very
   explicit consent flow.

Option 2 is the only one that preserves what Phase 1 guarantees. It should be
costed as a *notification* feature rather than an *automation* feature, because
that is what it is. If comment-tipping is a priority, this decision — not the
Meta API — is the one that determines whether the product stays what it claims
to be.

Whichever route is taken, the `AuthorizedIntent` gate stays. A server-side
trigger constructs a `PaymentIntent`; something with a human in it authorises.

---

## Obstacle 2: platform access

### Instagram comment triggers

Requires all of:

- The creator has a **Business or Creator** account (not personal).
- The creator completes **Facebook Login OAuth** granting our app
  `instagram_manage_comments` and related permissions.
- **App Review** approval from Meta for comment-webhook permissions, with a
  demonstrated use case and a privacy policy.
- An Instagram-connected Facebook Page.

Realistically a multi-week review with a genuine chance of rejection. Meta has
narrowed third-party comment access repeatedly. Treat approval as uncertain and
do not build a launch plan that depends on it.

The webhook receiver belongs in `Registry/` — it is HTTP, server-side, and next
to the creator records that would gate it. Opt-in must be explicit and per
creator.

### TikTok

**There is no equivalent.** TikTok offers no third-party API for reading
comments on a creator's video. Comment-triggered tipping is not available on
TikTok and should not be promised. The share-sheet flow is the TikTok story.

### App Clip (iOS)

A QR code at the end of a creator's video opens an App Clip that runs the same
payment engine.

- **Size:** App Clips are capped (currently 15 MB uncompressed for the newer
  format). Breez SDK plus a wallet UI is not obviously under that. The App Clip
  may need to be a *quote-and-handoff* rather than a full payment surface —
  worth prototyping early, because it changes the design.
- **Review:** discretionary, on top of the 3.1.1 organization-enrolment
  requirement that already applies to the main app.
- **Invocation:** App Clip Codes and URLs must be registered and associated with
  the domain. The registry service would serve the association file.
- **Wallet:** an App Clip has no access to the full app's keychain group by
  default, so a first-time App Clip user has no wallet. This flow is realistically
  "tip with a wallet you already have" (NWC) or "install the app", not
  "tip in one tap from cold".

### Instant App (Android)

Moot until Android exists. Same size and wallet-availability questions apply.

---

## If this is picked back up

In this order, and only once the current scope has shipped:

1. **Decide the custody question** (Obstacle 1) before applying for anything.
   The answer determines what you would even be asking Meta for, and whether
   the feature is still the product you set out to build.
2. **Prototype the App Clip size** with Breez linked. A real number beats a
   plan; it may force the App Clip to be quote-and-handoff rather than a full
   payment surface.
3. **Instagram shortcode posts** are a smaller, more valuable ask than comment
   webhooks — oEmbed access would close the one real gap in current share
   coverage. Worth pursuing first if any Meta review is going to be attempted.
4. **Submit Meta App Review** once 1 is settled.
5. Android port, if the iOS numbers justify it.
