import XCTest
@testable import TipMeCore

final class SendCapTests: XCTestCase {

    private func makeLedger(clock: MutableClock,
                            policy: SendCapPolicy = .standard) -> (SendCapLedger, InMemoryKeyValueStore) {
        let store = InMemoryKeyValueStore()
        return (SendCapLedger(store: store, clock: clock, policy: policy), store)
    }

    func testAllowsTipsUnderEveryLimit() async {
        let clock = MutableClock()
        let (ledger, _) = makeLedger(clock: clock)
        let decision = await ledger.evaluate(requested: .gbp(pence: 500))
        XCTAssertTrue(decision.isAllowed)
    }

    func testRejectsSingleTipOverPerTipCap() async {
        let clock = MutableClock()
        let (ledger, _) = makeLedger(clock: clock)
        let decision = await ledger.evaluate(requested: .gbp(pence: 2_001))
        XCTAssertFalse(decision.isAllowed)
        XCTAssertEqual(decision.userFacingReason, "Single tips are capped at £20.")
    }

    func testDailyCapAccumulates() async {
        let clock = MutableClock()
        let (ledger, _) = makeLedger(clock: clock)

        for _ in 0..<5 {
            await ledger.record(spent: .gbp(pence: 2_000)) // £100 total, at the cap
        }
        let decision = await ledger.evaluate(requested: .gbp(pence: 100))
        XCTAssertFalse(decision.isAllowed)
        if case .exceedsDaily(_, let spent, _) = decision {
            XCTAssertEqual(spent, .gbp(pence: 10_000))
        } else {
            XCTFail("expected a daily cap rejection, got \(decision)")
        }
    }

    func testDailyCapRollsOffAfterTwentyFourHours() async {
        let clock = MutableClock()
        let (ledger, _) = makeLedger(clock: clock)

        for _ in 0..<5 { await ledger.record(spent: .gbp(pence: 2_000)) }
        let atCap = await ledger.evaluate(requested: .gbp(pence: 100))
        XCTAssertFalse(atCap.isAllowed)

        clock.advance(by: 24 * 60 * 60 + 1)
        let afterRollOff = await ledger.evaluate(requested: .gbp(pence: 100))
        XCTAssertTrue(afterRollOff.isAllowed,
                      "the daily window is rolling, not calendar-based")
    }

    func testWeeklyCapStillBindsAfterDailyRollsOff() async {
        let clock = MutableClock()
        let (ledger, _) = makeLedger(clock: clock)

        // £100/day for three days = £300, which is exactly the weekly cap.
        for _ in 0..<3 {
            for _ in 0..<5 { await ledger.record(spent: .gbp(pence: 2_000)) }
            clock.advance(by: 24 * 60 * 60 + 1)
        }
        let decision = await ledger.evaluate(requested: .gbp(pence: 100))
        XCTAssertFalse(decision.isAllowed)
        guard case .exceedsWeekly = decision else {
            return XCTFail("expected a weekly cap rejection, got \(decision)")
        }
    }

    /// Caps are fiat-denominated precisely so that switching asset cannot be
    /// used to get around them.
    func testCapInAnUnknownCurrencyIsRefusedNotWaived() async {
        let clock = MutableClock()
        let (ledger, _) = makeLedger(clock: clock)
        let decision = await ledger.evaluate(requested: FiatAmount(currencyCode: "USD", minorUnits: 100))
        XCTAssertFalse(decision.isAllowed, "a cap we cannot evaluate must not be treated as satisfied")
    }

    /// The app and the share extension must count against one ledger.
    func testLedgerIsSharedAcrossSurfacesViaTheStore() async {
        let clock = MutableClock()
        let store = InMemoryKeyValueStore()

        let hostApp = SendCapLedger(store: store, clock: clock)
        for _ in 0..<5 { await hostApp.record(spent: .gbp(pence: 2_000)) }

        // A freshly constructed ledger, as the share extension would build.
        let shareExtension = SendCapLedger(store: store, clock: clock)
        let decision = await shareExtension.evaluate(requested: .gbp(pence: 100))
        XCTAssertFalse(decision.isAllowed,
                       "spending from one surface must count against the other")
    }
}

final class RateLimiterTests: XCTestCase {

    func testAllowsUpToTheSameHandleLimit() async {
        let clock = MutableClock()
        let limiter = TipRateLimiter(store: InMemoryKeyValueStore(), clock: clock)

        for _ in 0..<3 {
            let allowed = await limiter.evaluate(handleKey: "tiktok:creator")
            XCTAssertTrue(allowed.isAllowed)
            await limiter.record(handleKey: "tiktok:creator")
        }
        let fourth = await limiter.evaluate(handleKey: "tiktok:creator")
        XCTAssertFalse(fourth.isAllowed)
    }

    func testThrottlingIsPerHandle() async {
        let clock = MutableClock()
        let limiter = TipRateLimiter(store: InMemoryKeyValueStore(), clock: clock)

        for _ in 0..<3 { await limiter.record(handleKey: "tiktok:creator_a") }

        let sameCreator = await limiter.evaluate(handleKey: "tiktok:creator_a")
        let otherCreator = await limiter.evaluate(handleKey: "tiktok:creator_b")
        XCTAssertFalse(sameCreator.isAllowed)
        XCTAssertTrue(otherCreator.isAllowed,
                      "hitting the limit for one creator must not block a different one")
    }

    func testWindowSlides() async {
        let clock = MutableClock()
        let limiter = TipRateLimiter(store: InMemoryKeyValueStore(), clock: clock)

        for _ in 0..<3 { await limiter.record(handleKey: "tiktok:creator") }
        let withinWindow = await limiter.evaluate(handleKey: "tiktok:creator")
        XCTAssertFalse(withinWindow.isAllowed)

        clock.advance(by: 601)
        let afterWindow = await limiter.evaluate(handleKey: "tiktok:creator")
        XCTAssertTrue(afterWindow.isAllowed)
    }

    func testGlobalLimitCatchesSpreadOutBursts() async {
        let clock = MutableClock()
        let limiter = TipRateLimiter(store: InMemoryKeyValueStore(), clock: clock)

        // 20 tips to 20 different creators trips no per-handle limit, but is
        // exactly the pattern a drained wallet looks like.
        for index in 0..<20 {
            await limiter.record(handleKey: "tiktok:creator\(index)")
        }
        let decision = await limiter.evaluate(handleKey: "tiktok:someone_new")
        XCTAssertFalse(decision.isAllowed)
        guard case .globallyThrottled = decision else {
            return XCTFail("expected a global throttle, got \(decision)")
        }
    }

    func testRetryAfterIsReported() async {
        let clock = MutableClock()
        let limiter = TipRateLimiter(store: InMemoryKeyValueStore(), clock: clock)

        for _ in 0..<3 { await limiter.record(handleKey: "tiktok:creator") }
        clock.advance(by: 300)

        let decision = await limiter.evaluate(handleKey: "tiktok:creator")
        guard case .sameHandleThrottled(let retryAfter, _, _) = decision else {
            return XCTFail("expected a same-handle throttle")
        }
        XCTAssertEqual(retryAfter, 300, accuracy: 1)
    }
}

final class AuditLogTests: XCTestCase {

    private func makeEvent(stage: AuditEvent.Stage, outcome: AuditEvent.Outcome = .ok) -> AuditEvent {
        AuditEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                   intentID: "11111111-1111-1111-1111-111111111111",
                   stage: stage,
                   outcome: outcome,
                   origin: "shareExtension",
                   platform: "tiktok",
                   handle: "creator",
                   destination: "cr***@getalby.com",
                   asset: "bitcoin",
                   tipMinorUnits: 2_000,
                   feeMinorUnits: 60,
                   fiatCurrency: "GBP",
                   fiatMinorUnits: 103)
    }

    func testEachEventIsExactlyOneJSONLine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = JSONLinesAuditLog(fileURL: url)
        await log.append(makeEvent(stage: .tipPaymentAttempted))
        await log.append(makeEvent(stage: .tipPaymentSucceeded))

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)),
                             "every line must stand alone as valid JSON")
        }
    }

    /// A truncated write should cost the last line only. A single JSON array
    /// would be unreadable after any interrupted write, and this code runs in
    /// an app extension the OS can kill mid-payment.
    func testTruncatedTailStillLeavesEarlierLinesReadable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = JSONLinesAuditLog(fileURL: url)
        await log.append(makeEvent(stage: .tipPaymentAttempted))
        await log.append(makeEvent(stage: .tipPaymentSucceeded))

        var data = try Data(contentsOf: url)
        data = data.dropLast(20) // simulate a killed process mid-write
        try data.write(to: url)

        let recovered = await log.readAll()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.stage, .tipPaymentAttempted)
    }

    func testLogDoesNotContainUnredactedDestinations() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = JSONLinesAuditLog(fileURL: url)
        await log.append(makeEvent(stage: .settled))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("cr***@getalby.com"))
        XCTAssertFalse(text.contains("creator@getalby.com"),
                       "audit logs outlive payments; they must not become a directory of who tipped whom")
    }

    func testRoundTripsEveryField() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = JSONLinesAuditLog(fileURL: url)
        let original = makeEvent(stage: .settled, outcome: .ok)
        await log.append(original)

        let recovered = await log.readAll()
        XCTAssertEqual(recovered, [original])
    }
}
