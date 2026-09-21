import Foundation

/// Creators this account has tipped, most recent first, so one can be tipped
/// again in a tap. Kept per signed-in account: a device that switches accounts
/// must not show the previous person's history.
public struct RecentTipStore: Sendable {
    public struct Entry: Equatable, Codable, Sendable {
        public let handle: CreatorHandle
        public let lastTippedAt: Date
    }

    public static let capacity = 20

    private let store: KeyValueStore
    private let userID: String

    public init(store: KeyValueStore, userID: String) {
        self.store = store
        self.userID = userID
    }

    private var key: String { "recent-tips.\(userID)" }

    public func all() -> [Entry] {
        guard let data = store.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    public func record(_ handle: CreatorHandle, at date: Date = Date()) {
        var entries = all().filter { $0.handle != handle }
        entries.insert(Entry(handle: handle, lastTippedAt: date), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        store.set(try? encoder.encode(entries), forKey: key)
    }

    public func remove(_ handle: CreatorHandle) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        store.set(try? encoder.encode(all().filter { $0.handle != handle }), forKey: key)
    }
}
