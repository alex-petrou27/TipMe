import Foundation

/// Where a creator handle came from, which is not a detail — it determines how
/// much we should trust it.
public enum HandleSource: String, Equatable, Sendable {
    /// Read out of the URL path, e.g. `tiktok.com/@user/video/123`. Highest
    /// confidence: the platform put it there.
    case url
    /// Read out of the share sheet's own title, e.g. "Reel from @natgeo".
    /// High confidence, but prose rather than a structured field — which is
    /// why the extraction rules below decline rather than guess. As with every
    /// other source, the handle is shown on the amount picker and again on the
    /// confirm screen before anything is sent.
    case shareTitle
    /// The user typed or pasted a destination themselves.
    case manual
}

/// Recovers a creator handle from the share sheet's title.
///
/// ## Why this matters
///
/// Instagram Reel and post URLs are shortcode-keyed and carry no username, so
/// for a long time the assumption was that those shares were unidentifiable
/// without Meta App Review. That was wrong: **the handle is in the payload, it
/// is just not in the URL.** When Instagram shares a Reel, the system share
/// sheet's header reads "Reel from @username", and that string reaches the
/// extension as the item's title.
///
/// So a Reel share is identifiable after all, with no API access at all.
///
/// ## Why it is conservative
///
/// Titles are prose, not a structured field. A caption that tags other accounts
/// would let a naive "first @mention wins" rule tip the wrong person, which is
/// unrecoverable. The rules are therefore ordered by confidence and decline
/// rather than guess:
///
/// 1. An explicit attribution — "Reel **from** @user", "Post **by** @user".
/// 2. "@user **on** Instagram".
/// 3. A single unambiguous mention. If the title mentions more than one
///    distinct account, nothing is returned.
public struct ShareTitleParser: Sendable {

    public init() {}

    /// A mention must not follow a word character. Without this,
    /// "support@instagram.com" yields a creator called `instagram.com`.
    private static let mentionPrefix = "(?<![A-Za-z0-9._])@"
    private static let username = "([A-Za-z0-9._]+)"

    private static let attribution = try! NSRegularExpression(
        pattern: "\\b(?:from|by)\\s+" + mentionPrefix + username,
        options: [.caseInsensitive])

    private static let onPlatform = try! NSRegularExpression(
        pattern: mentionPrefix + username + "\\s+on\\s+(?:instagram|tiktok)",
        options: [.caseInsensitive])

    private static let anyMention = try! NSRegularExpression(
        pattern: mentionPrefix + username,
        options: [])

    /// Extracts a handle, or `nil` if the title does not unambiguously name one.
    public func handle(in title: String, platform: Platform) -> CreatorHandle? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Explicit attribution wins even when other accounts are mentioned:
        //    "Reel from @natgeo ft. @nasa" is about @natgeo.
        if let handle = firstMatch(Self.attribution, in: trimmed, platform: platform) {
            return handle
        }

        // 2. "@natgeo on Instagram"
        if let handle = firstMatch(Self.onPlatform, in: trimmed, platform: platform) {
            return handle
        }

        // 3. A single distinct mention is unambiguous. Several are not, and
        //    guessing between them risks paying the wrong person.
        let mentions = allMatches(Self.anyMention, in: trimmed, platform: platform)
        let distinct = Set(mentions.map(\.username))
        return distinct.count == 1 ? mentions.first : nil
    }

    /// Tries several candidate strings in order — a share may provide a title,
    /// a subject and link metadata, and only one of them may carry the handle.
    public func handle(inAnyOf titles: [String], platform: Platform) -> CreatorHandle? {
        for title in titles {
            if let handle = handle(in: title, platform: platform) { return handle }
        }
        return nil
    }

    // MARK: - Matching

    private func firstMatch(_ regex: NSRegularExpression,
                            in text: String,
                            platform: Platform) -> CreatorHandle? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return CreatorHandle(platform: platform, rawUsername: String(text[captured]))
    }

    private func allMatches(_ regex: NSRegularExpression,
                            in text: String,
                            platform: Platform) -> [CreatorHandle] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: text) else { return nil }
            return CreatorHandle(platform: platform, rawUsername: String(text[captured]))
        }
    }
}
