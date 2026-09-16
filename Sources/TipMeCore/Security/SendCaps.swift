import Foundation

/// Per-user spending ceilings.
///
/// Expressed in a single fiat currency on purpose. Caps denominated per-asset
/// would be trivially bypassed by switching asset, and a sats-denominated cap
/// silently changes meaning every time the Bitcoin price moves.
public struct SendCapPolicy: Equatable, Codable, Sendable {
    public var currencyCode: String
    public var perTip: Int64
    public var perDay: Int64
    public var perWeek: Int64

    public init(currencyCode: String = "GBP", perTip: Int64, perDay: Int64, perWeek: Int64) {
        precondition(perTip > 0 && perDay >= perTip && perWeek >= perDay,
                     "cap policy must be internally consistent")
        self.currencyCode = currencyCode.uppercased()
        self.perTip = perTip
        self.perDay = perDay
        self.perWeek = perWeek
    }

    public static let standard = SendCapPolicy(perTip: 2_000, perDay: 10_000, perWeek: 30_000)
}

public enum SendCapDecision: Equatable, Sendable {
    case allowed
    case exceedsPerTip(limit: FiatAmount, requested: FiatAmount)
    case exceedsDaily(limit: FiatAmount, spent: FiatAmount, requested: FiatAmount)
    case exceedsWeekly(limit: FiatAmount, spent: FiatAmount, requested: FiatAmount)

    public var isAllowed: Bool { self == .allowed }

    public var userFacingReason: String? {
        switch self {
        case .allowed:
            return nil
        case .exceedsPerTip(let limit, _):
            return "Single tips are capped at \(limit.formatted)."
        case .exceedsDaily(let limit, let spent, _):
            return "That would pass your \(limit.formatted) daily limit — you've tipped \(spent.formatted) today."
        case .exceedsWeekly(let limit, let spent, _):
            return "That would pass your \(limit.formatted) weekly limit — you've tipped \(spent.formatted) this week."
        }
    }
}

/// Tracks spend against the cap policy.
///
/// Persisted through `KeyValueStore`, which on iOS is the shared App Group
/// container. Both the app and the share extension therefore count against one
/// ledger; if the extension kept its own, the caps would reset every time the
/// user tipped from a different entry point.
public actor SendCapLedger {
    private struct Entry: Codable, Sendable {
        let at: Date
        let currencyCode: String
        let minorUnits: Int64
    }

    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let store: KeyValueStore
    private let clock: Clock
    private var policy: SendCapPolicy
    /// Distinguishes independent ledgers sharing one `KeyValueStore` — the
    /// tipping cap and the general wallet-send cap are deliberately separate,
    /// so a day of ordinary wallet spending cannot exhaust a creator tip's
    /// budget or vice versa.
    private let storageKey: String

    public init(store: KeyValueStore, clock: Clock = SystemClock(),
                policy: SendCapPolicy = .standard, namespace: String = "tips") {
        self.store = store
        self.clock = clock
        self.policy = policy
        self.storageKey = "tipme.sendcaps.\(namespace).v1"
    }

    public func updatePolicy(_ newPolicy: SendCapPolicy) { policy = newPolicy }

    /// Would this tip be allowed right now? `requested` is the **total** the
    /// user's wallet is debited — tip plus our fee — because that is what
    /// actually leaves their balance.
    public func evaluate(requested: FiatAmount) -> SendCapDecision {
        guard requested.currencyCode == policy.currencyCode else {
            // A cap we cannot evaluate is a cap we must not waive.
            return .exceedsPerTip(limit: FiatAmount(currencyCode: policy.currencyCode, minorUnits: policy.perTip),
                                  requested: requested)
        }

        if requested.minorUnits > policy.perTip {
            return .exceedsPerTip(limit: FiatAmount(currencyCode: policy.currencyCode, minorUnits: policy.perTip),
                                  requested: requested)
        }

        let now = clock.now
        let entries = load()
        let daySpent = total(of: entries, since: now.addingTimeInterval(-24 * 60 * 60))
        if daySpent + requested.minorUnits > policy.perDay {
            return .exceedsDaily(limit: FiatAmount(currencyCode: policy.currencyCode, minorUnits: policy.perDay),
                                 spent: FiatAmount(currencyCode: policy.currencyCode, minorUnits: daySpent),
                                 requested: requested)
        }

        let weekSpent = total(of: entries, since: now.addingTimeInterval(-Self.retention))
        if weekSpent + requested.minorUnits > policy.perWeek {
            return .exceedsWeekly(limit: FiatAmount(currencyCode: policy.currencyCode, minorUnits: policy.perWeek),
                                  spent: FiatAmount(currencyCode: policy.currencyCode, minorUnits: weekSpent),
                                  requested: requested)
        }

        return .allowed
    }

    /// Recorded only once a payment has actually been attempted against the
    /// network, so a user who abandons a confirm sheet doesn't burn their cap.
    public func record(spent: FiatAmount) {
        var entries = load()
        entries.append(Entry(at: clock.now, currencyCode: spent.currencyCode, minorUnits: spent.minorUnits))
        save(entries)
    }

    public func spentToday() -> FiatAmount {
        FiatAmount(currencyCode: policy.currencyCode,
                   minorUnits: total(of: load(), since: clock.now.addingTimeInterval(-24 * 60 * 60)))
    }

    private func total(of entries: [Entry], since cutoff: Date) -> Int64 {
        entries.filter { $0.at >= cutoff && $0.currencyCode == policy.currencyCode }
               .reduce(Int64(0)) { $0 + $1.minorUnits }
    }

    private func load() -> [Entry] {
        let cutoff = clock.now.addingTimeInterval(-Self.retention)
        return (store.decode([Entry].self, forKey: storageKey) ?? []).filter { $0.at >= cutoff }
    }

    private func save(_ entries: [Entry]) {
        let cutoff = clock.now.addingTimeInterval(-Self.retention)
        store.encode(entries.filter { $0.at >= cutoff }, forKey: storageKey)
    }
}
