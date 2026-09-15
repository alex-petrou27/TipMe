import Foundation

public struct RateLimitPolicy: Equatable, Codable, Sendable {
    /// Max tips to one creator within `sameHandleWindow`.
    public var sameHandleCount: Int
    public var sameHandleWindow: TimeInterval
    /// Max tips overall within `globalWindow`.
    public var globalCount: Int
    public var globalWindow: TimeInterval

    public init(sameHandleCount: Int = 3, sameHandleWindow: TimeInterval = 600,
                globalCount: Int = 20, globalWindow: TimeInterval = 3600) {
        self.sameHandleCount = sameHandleCount
        self.sameHandleWindow = sameHandleWindow
        self.globalCount = globalCount
        self.globalWindow = globalWindow
    }

    public static let standard = RateLimitPolicy()
}

public enum RateLimitDecision: Equatable, Sendable {
    case allowed
    case sameHandleThrottled(retryAfter: TimeInterval, limit: Int, window: TimeInterval)
    case globallyThrottled(retryAfter: TimeInterval, limit: Int, window: TimeInterval)

    public var isAllowed: Bool { self == .allowed }

    public var userFacingReason: String? {
        switch self {
        case .allowed:
            return nil
        case .sameHandleThrottled(let retryAfter, let limit, _):
            return "You've tipped this creator \(limit) times just now. Try again in \(Self.describe(retryAfter))."
        case .globallyThrottled(let retryAfter, _, _):
            return "You're tipping unusually fast. Try again in \(Self.describe(retryAfter))."
        }
    }

    private static func describe(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded(.up)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(Int((Double(seconds) / 60).rounded(.up)))m"
    }
}

/// Sliding-window rate limiter over tip attempts.
///
/// Guards against two different things: a shaky thumb double-firing a payment,
/// and a compromised or automated caller draining a wallet in a burst. The
/// same-handle window is the one that matters for the first; the global window
/// is the one that matters for the second.
public actor TipRateLimiter {
    private struct Attempt: Codable, Sendable {
        let at: Date
        let handleKey: String
    }

    private static let storageKey = "tipme.ratelimit.attempts.v1"

    private let store: KeyValueStore
    private let clock: Clock
    private var policy: RateLimitPolicy

    public init(store: KeyValueStore, clock: Clock = SystemClock(), policy: RateLimitPolicy = .standard) {
        self.store = store
        self.clock = clock
        self.policy = policy
    }

    public func updatePolicy(_ newPolicy: RateLimitPolicy) { policy = newPolicy }

    public func evaluate(handleKey: String) -> RateLimitDecision {
        let now = clock.now
        let attempts = load()

        let sameHandle = attempts
            .filter { $0.handleKey == handleKey && now.timeIntervalSince($0.at) < policy.sameHandleWindow }
            .sorted { $0.at < $1.at }
        if sameHandle.count >= policy.sameHandleCount, let oldest = sameHandle.first {
            let retryAfter = policy.sameHandleWindow - now.timeIntervalSince(oldest.at)
            return .sameHandleThrottled(retryAfter: max(0, retryAfter),
                                        limit: policy.sameHandleCount,
                                        window: policy.sameHandleWindow)
        }

        let global = attempts
            .filter { now.timeIntervalSince($0.at) < policy.globalWindow }
            .sorted { $0.at < $1.at }
        if global.count >= policy.globalCount, let oldest = global.first {
            let retryAfter = policy.globalWindow - now.timeIntervalSince(oldest.at)
            return .globallyThrottled(retryAfter: max(0, retryAfter),
                                      limit: policy.globalCount,
                                      window: policy.globalWindow)
        }

        return .allowed
    }

    /// Records an attempt. Called for every attempt that reaches the network,
    /// including failures — otherwise a caller could retry a failing payment
    /// without limit.
    public func record(handleKey: String) {
        var attempts = load()
        attempts.append(Attempt(at: clock.now, handleKey: handleKey))
        save(attempts)
    }

    private func load() -> [Attempt] {
        let horizon = max(policy.sameHandleWindow, policy.globalWindow)
        let cutoff = clock.now.addingTimeInterval(-horizon)
        return (store.decode([Attempt].self, forKey: Self.storageKey) ?? []).filter { $0.at >= cutoff }
    }

    private func save(_ attempts: [Attempt]) {
        let horizon = max(policy.sameHandleWindow, policy.globalWindow)
        let cutoff = clock.now.addingTimeInterval(-horizon)
        store.encode(attempts.filter { $0.at >= cutoff }, forKey: Self.storageKey)
    }
}
