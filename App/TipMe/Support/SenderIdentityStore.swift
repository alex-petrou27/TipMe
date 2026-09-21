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

    /// Every account connected on this platform, oldest first. Stored as a JSON
    /// list; a bare string from before multiple accounts were allowed is read
    /// as a one-item list.
    public func usernames(for platform: Platform) -> [String] {
        guard let data = store.data(forKey: key(for: platform)) else { return [] }
        if let list = try? JSONDecoder().decode([String].self, from: data) { return list }
        return String(data: data, encoding: .utf8).map { [$0] } ?? []
    }

    /// Adds an account; connecting the same one twice (ignoring case) is a no-op.
    public func add(username: String, for platform: Platform) {
        var list = usernames(for: platform)
        guard !list.contains(where: { $0.caseInsensitiveCompare(username) == .orderedSame }) else { return }
        list.append(username)
        save(list, for: platform)
    }

    public func remove(username: String, for platform: Platform) {
        save(usernames(for: platform).filter { $0.caseInsensitiveCompare(username) != .orderedSame },
             for: platform)
    }

    private func save(_ list: [String], for platform: Platform) {
        store.set(list.isEmpty ? nil : try? JSONEncoder().encode(list), forKey: key(for: platform))
    }
}
