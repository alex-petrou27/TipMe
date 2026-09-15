import Foundation
import UIKit
import TipMeCore

/// Detects that the user has copied a link, without reading it.
///
/// ## Why this exists
///
/// TipMe cannot appear in TikTok's or Instagram's own share row — those slots
/// (Repost, WhatsApp, Messenger, Telegram, SMS, Copy link) are hardcoded
/// first-party integrations with no third-party API. TipMe reaches the user via
/// the **More / Share to…** button, which opens the iOS system share sheet.
///
/// But **Copy link** *is* in that prominent first row, on both apps. So the
/// second-best position is to be what the user does immediately afterwards:
/// they copy the link, open TipMe, and the tip is already waiting for them.
///
/// ## Why it does not just read the pasteboard
///
/// Touching `UIPasteboard.general.string` shows the system "TipMe pasted from
/// TikTok" banner and hands us the content whether we needed it or not. For an
/// app that opens straight onto a wallet, silently reading the clipboard on
/// every launch is exactly the behaviour that gets an app written about.
///
/// `detectPatterns` answers only "is there probably a web URL on the clipboard"
/// — no banner, no content. We use that to decide whether to offer anything at
/// all, and the actual content only ever arrives through a `PasteButton` the
/// user taps themselves.
public enum ClipboardLinkDetector {

    /// True when the clipboard probably holds a web URL. Never returns the URL.
    public static func containsProbableLink() async -> Bool {
        await withCheckedContinuation { continuation in
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                switch result {
                case .success(let patterns):
                    continuation.resume(returning: patterns.contains(.probableWebURL))
                case .failure:
                    // Detection can fail if another app holds the pasteboard.
                    // Offering nothing is the right answer; the share-sheet
                    // path still works.
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Turns pasted content into a payload the tip sheet can act on.
    ///
    /// Accepts text as well as URLs, because "Copy link" on some versions puts
    /// the link inside a sentence rather than on its own, and because a user
    /// may paste from Notes or a message thread.
    public static func payload(fromPastedURLs urls: [URL], text: [String]) -> SharedPayload {
        SharedPayload(urls: urls, text: text)
    }

    /// Whether a payload contains something worth opening the tip sheet for.
    ///
    /// Checked before presenting anything, so a user who copied an unrelated
    /// link is not shown a tip sheet that immediately dead-ends.
    public static func looksTippable(_ payload: SharedPayload,
                                     parser: SharedLinkParser = SharedLinkParser()) -> Bool {
        let extractor = SharedPayloadExtractor()
        let candidates = extractor.candidateURLs(attachedURLs: payload.urls, sharedText: payload.text)
        return extractor.bestLink(from: candidates, parser: parser) != nil
    }
}
