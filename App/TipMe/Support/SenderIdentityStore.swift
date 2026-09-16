import Foundation
import TipMeCore

/// What the sender has told TipMe about their own social handles — each one
/// proven via the identity-only sign-in
/// (`SocialAccountConnector.connectIdentity`), not just typed in.
///
/// Purely a "Sending as @you" convenience. Unlike `CreatorTokenStore`,
/// nothing stored here is a secret or controls where money goes, so it lives
/// in the shared App Group's plain `UserDefaults` rather than the keychain —
/// and unlike a creator record, it is never sent to the registry at all.
public struct SenderIdentityStore: Sendable {
    private let store: KeyValueStore

    public init?(appGroup: String) {
        guard let store = AppGroupKeyValueStore(appGroup: appGroup) else { return nil }
        self.store = store
    }

    private func key(for platform: Platform) -> String { "sender-identity.\(platform.rawValue)" }

    public func username(for platform: Platform) -> String? {
        store.data(forKey: key(for: platform)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func set(username: String, for platform: Platform) {
        store.set(username.data(using: .utf8), forKey: key(for: platform))
    }

    public func clear(_ platform: Platform) {
        store.set(nil, forKey: key(for: platform))
    }
}
