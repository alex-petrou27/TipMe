import Foundation

/// Injectable time source. The security gates (caps, rate limits) are only
/// testable — and only trustworthy — if time is explicit rather than ambient.
public protocol Clock: Sendable {
    var now: Date { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// Test clock. Not `@testable`-only on purpose: the registry simulator and the
/// dry-run harness in `docs/` both drive it.
public final class MutableClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}
