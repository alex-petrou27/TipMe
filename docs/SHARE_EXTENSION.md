# The share extension

Everything the product promises happens in about two seconds inside a process
the OS is willing to kill at any moment. This is what that constrains.

## Lifecycle

1. User taps **Share** in TikTok/Instagram/Safari and picks **Tip via TipMe**.
2. iOS launches `TipMeShare` and presents `ShareViewController` as a sheet over
   the host app. No app switch — this is the native behaviour of a
   `com.apple.share-services` extension, and it is the core mechanic.
3. `ShareViewController` reads `NSExtensionItem` attachments and starts work
   immediately. There is no splash and no warm-up.
4. `TipFlow` parses, resolves the creator, quotes, prompts for Face ID, pays.
5. `extensionContext.completeRequest` returns control to the host app — on
   **every** exit path, including failures. An extension that forgets this
   leaves the host app's share sheet wedged.

## Memory

Share extensions run under a hard jetsam cap, far tighter than an app's, and a
termination looks like the sheet vanishing rather than a crash dialog.

The mitigation is that the extension never cold-starts the wallet:

- The host app connects Breez and syncs on foreground, into a working directory
  inside the shared App Group container.
- The extension opens that same directory and performs an incremental sync.
- Connection happens concurrently with link parsing, because they are
  independent and every serialised millisecond is a millisecond the user spends
  watching a spinner over their feed.

If you see jetsam terminations in testing, check whether the host app has run
recently. A user who installs TipMe, never opens it, and shares straight from
TikTok has no synced wallet — which is why the extension refuses to run at all
without one, with a message pointing at the app.

The creator-record cache is bounded (`CachingCreatorResolver`, 64 entries) for
the same reason: an unbounded cache here is a crash, not a speedup.

## What the OS actually hands over

Inconsistent across platforms and versions, so both shapes are handled:

- **Safari / Chrome** provide a clean `public.url` attachment.
- **TikTok** frequently provides `public.plain-text` containing marketing copy
  with the link embedded: `"Check out this video! https://vm.tiktok.com/… #fyp"`.
- **Instagram** varies by version.

`SharedPayloadExtractor` collects URL attachments and text, scans the text with
`NSDataDetector`, de-duplicates, and ranks candidates: an explicit attachment
beats a link scraped from a caption, and a link carrying a handle beats a short
link that still needs resolving.

This is also why the activation rule in `Info.plist` accepts
`NSExtensionActivationSupportsText` as well as URLs. A URL-only rule would make
TipMe invisible in the share sheet for a large share of real TikTok shares.

Note that iOS activation predicates cannot match on a URL's *host*, so TipMe
appears in the share sheet for any link. Deciding whether a link is one of ours
happens in `SharedLinkParser`, and anything unrecognised falls through to
manual entry.

## Sharing state with the app

Three things cross the process boundary, all of which must be configured
identically on both targets:

| What | Mechanism | Why |
|---|---|---|
| Wallet working directory | App Group container | Warm sync (above) |
| Send caps, rate limits | App Group `UserDefaults` | One ledger, not two |
| Audit log | App Group file | One complete record |
| Mnemonic | Shared keychain access group | Extension must sign payments |

The caps and rate limits are the security-relevant ones. If each process kept
its own counters, every limit could be reset simply by switching entry point.

The mnemonic is stored `WhenUnlockedThisDeviceOnly`: *WhenUnlocked* because an
extension only ever runs while someone is looking at their phone, and
*ThisDeviceOnly* because it controls real funds and must not ride an iCloud
Keychain sync onto another device.

## Biometrics inside an extension

`LocalAuthentication` works normally. Two choices worth knowing about:

- `.deviceOwnerAuthentication` rather than `…WithBiometrics`, so a user whose
  Face ID fails in bad light can still complete a tip with their passcode.
  Both paths require a present human.
- A fresh `LAContext` per evaluation with `touchIDAuthenticationAllowableReuseDuration`
  left at zero. iOS would otherwise let a recent unlock satisfy a later prompt
  with nothing shown — a payment firing with no visible confirmation. Every tip
  gets its own prompt.

## Why the simulator is not enough

No TikTok or Instagram to share *from*, no Face ID hardware, and a share sheet
that does not reproduce the real extension lifecycle or memory pressure. The
parsing, fee, cap, rate-limit and engine logic are all covered by `swift test`
on the host; the device is for the integration itself.
