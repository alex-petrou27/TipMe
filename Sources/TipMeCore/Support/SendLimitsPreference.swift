import Foundation

/// Send limits the user has set themselves, in minor units of their currency.
/// Nothing saved means the build's defaults apply.
public struct SendLimitsPreference: Sendable {
    public struct Limits: Equatable, Codable, Sendable {
        public var perTip: Int64
        public var perDay: Int64
        public var perWeek: Int64

        public init(perTip: Int64, perDay: Int64, perWeek: Int64) {
            self.perTip = perTip
            self.perDay = perDay
            self.perWeek = perWeek
        }

        /// A single tip can't exceed a day's limit, nor a day a week's -- the
        /// same rule `SendCapPolicy` enforces (by crashing), checked here first.
        public var isConsistent: Bool {
            perTip > 0 && perDay >= perTip && perWeek >= perDay
        }
    }

    private static let key = "send-limits"
    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    public var saved: Limits? {
        guard let data = store.data(forKey: Self.key),
              let limits = try? JSONDecoder().decode(Limits.self, from: data),
              limits.isConsistent
        else { return nil }
        return limits
    }

    /// Returns false, saving nothing, for an inconsistent set.
    @discardableResult
    public func save(_ limits: Limits) -> Bool {
        guard limits.isConsistent, let data = try? JSONEncoder().encode(limits) else { return false }
        store.set(data, forKey: Self.key)
        return true
    }
}
