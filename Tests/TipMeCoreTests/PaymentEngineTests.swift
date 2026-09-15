import XCTest
@testable import TipMeCore

final class PaymentEngineTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let clock: MutableClock
        let backend: FakePaymentBackend
        let engine: PaymentEngine
        let gate: AuthorizationGate
        let audit: InMemoryAuditLog
        let capLedger: SendCapLedger
        let rateLimiter: TipRateLimiter
        let quoteBuilder: TipQuoteBuilder
    }

    private func makeHarness(authorizer: BiometricAuthorizer = FakeAuthorizer(),
                             feePolicy: FeePolicy = .standard,
                             capPolicy: SendCapPolicy = .standard,
                             rateLimitPolicy: RateLimitPolicy = .standard) -> Harness {
        let clock = MutableClock()
        let backend = FakePaymentBackend(clock: clock)
        let audit = InMemoryAuditLog()
        let store = InMemoryKeyValueStore()
        let capLedger = SendCapLedger(store: store, clock: clock, policy: capPolicy)
        let rateLimiter = TipRateLimiter(store: store, clock: clock, policy: rateLimitPolicy)

        return Harness(
            clock: clock,
            backend: backend,
            engine: PaymentEngine(backend: backend,
                                  capLedger: capLedger,
                                  rateLimiter: rateLimiter,
                                  auditLog: audit,
                                  feeDestination: Fixtures.feeDestination,
                                  clock: clock),
            gate: AuthorizationGate(authorizer: authorizer, clock: clock, auditLog: audit),
            audit: audit,
            capLedger: capLedger,
            rateLimiter: rateLimiter,
            quoteBuilder: TipQuoteBuilder(feePolicy: feePolicy))
    }

    /// Builds a quote through the same path production uses.
    private func makeQuote(_ harness: Harness,
                           tip: Amount = .sats(2_000),
                           creator: CreatorRecord = .stub()) async throws -> TipQuote {
        let route = try await harness.backend.prepareRoute(tip: tip,
                                                           to: creator.lightningAddress,
                                                           receiveAsset: creator.preferredAsset)
        let rate = try await harness.backend.rate(for: tip.asset, in: "GBP")
        return try harness.quoteBuilder.quote(tip: tip, route: route, sendRate: rate)
    }

    private func authorize(_ harness: Harness,
                           quote: TipQuote,
                           creator: CreatorRecord = .stub()) async throws -> AuthorizedIntent {
        let intent = PaymentIntent(quote: quote, creator: creator, sourceLink: nil,
                                   origin: .shareExtension, createdAt: harness.clock.now)
        return try await harness.gate.authorize(intent)
    }

    // MARK: - The two-payment fee flow

    /// The ordering guarantee: the creator is paid first, always. If only one of
    /// the two payments can land, it must be theirs.
    func testTipIsSentBeforeTheFee() async throws {
        let harness = makeHarness()
        let creator = CreatorRecord.stub()
        let quote = try await makeQuote(harness, creator: creator)
        let authorized = try await authorize(harness, quote: quote, creator: creator)

        _ = try await harness.engine.execute(authorized)

        let sends = await harness.backend.recordedSends()
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[0].destination, creator.lightningAddress)
        XCTAssertEqual(sends[1].destination, Fixtures.feeDestination)
    }

    func testCreatorReceivesTheFullTipAndTheFeeIsSeparate() async throws {
        let harness = makeHarness()
        let creator = CreatorRecord.stub()
        let quote = try await makeQuote(harness, tip: .sats(2_000), creator: creator)

        XCTAssertEqual(quote.creatorReceives, .sats(2_000), "the creator is never skimmed")
        XCTAssertEqual(quote.fee, .sats(60))
        XCTAssertEqual(quote.senderPays, .sats(2_060), "the sender pays tip + fee")
        XCTAssertEqual(quote.disclosure, "£1.00 tip + £0.03 fee = £1.03")

        _ = try await harness.engine.execute(try await authorize(harness, quote: quote, creator: creator))

        let sends = await harness.backend.recordedSends()
        XCTAssertEqual(sends[0].route.credited, .sats(2_000))
        XCTAssertEqual(sends[1].route.debited, .sats(60))
    }

    func testTheTwoPaymentsUseDistinctIdempotencyKeys() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        _ = try await harness.engine.execute(try await authorize(harness, quote: quote))

        let sends = await harness.backend.recordedSends()
        XCTAssertTrue(sends[0].idempotencyKey.hasSuffix(":tip"))
        XCTAssertTrue(sends[1].idempotencyKey.hasSuffix(":fee"))
        XCTAssertNotEqual(sends[0].idempotencyKey, sends[1].idempotencyKey,
                          "sharing a key would make the backend collapse the two payments into one")
    }

    /// A failed fee collection is our problem, not the user's. The creator has
    /// been paid, so reporting this as a failed tip would be a lie.
    func testFeeFailureDoesNotFailTheTip() async throws {
        let harness = makeHarness()
        await harness.backend.failSends(to: Fixtures.feeDestination,
                                        with: .network("fee route unavailable"))

        let quote = try await makeQuote(harness)
        let result = try await harness.engine.execute(try await authorize(harness, quote: quote))

        XCTAssertTrue(result.creatorWasPaid)
        XCTAssertNil(result.feeReceipt)
        XCTAssertNotNil(result.feeCollectionFailed)

        let stages = await harness.audit.stages()
        XCTAssertTrue(stages.contains(.tipPaymentSucceeded))
        XCTAssertTrue(stages.contains(.feePaymentFailed))
    }

    func testFailedTipDoesNotAttemptTheFee() async throws {
        let harness = makeHarness()
        let creator = CreatorRecord.stub()
        await harness.backend.failSends(to: creator.lightningAddress, with: .network("no route"))

        let quote = try await makeQuote(harness, creator: creator)
        let authorized = try await authorize(harness, quote: quote, creator: creator)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected the tip to fail")
        } catch PaymentEngineError.backend {
            let sends = await harness.backend.recordedSends()
            XCTAssertEqual(sends.count, 1, "we must not charge a fee for a tip that never landed")
        }
    }

    func testWaivedFeeSendsOnlyOnePayment() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness, tip: .sats(500)) // below the waiver
        XCTAssertFalse(quote.hasFee)

        let result = try await harness.engine.execute(try await authorize(harness, quote: quote))

        XCTAssertNil(result.feeReceipt)
        XCTAssertNil(result.feeCollectionFailed)
        let sends = await harness.backend.recordedSends()
        XCTAssertEqual(sends.count, 1)
    }

    // MARK: - Replay and expiry

    func testAnAuthorizationCannotBeSpentTwice() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        let authorized = try await authorize(harness, quote: quote)

        _ = try await harness.engine.execute(authorized)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("a single-use token was accepted twice")
        } catch PaymentEngineError.intentAlreadyExecuted {
            let sends = await harness.backend.recordedSends()
            XCTAssertEqual(sends.count, 2, "no extra payments from the replay")
        }
    }

    func testExpiredAuthorizationIsRejected() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        let authorized = try await authorize(harness, quote: quote)

        harness.clock.advance(by: AuthorizationGate.approvalValidity + 1)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected the stale approval to be rejected")
        } catch PaymentEngineError.intentExpired {
            let sends = await harness.backend.recordedSends()
            XCTAssertTrue(sends.isEmpty)
        }
    }

    /// The specific failure this prevents: the sheet shows "£1.00 + £0.03", the
    /// user leaves it open, the Bitcoin price moves, and Face ID then authorises
    /// a sat amount that no longer matches the pounds they agreed to.
    ///
    /// Note the shape of the window this has to construct. An approval lives 60s
    /// but a rate may be spent up to 120s old, so a quote that was *fresh* when
    /// confirmed can never trip the rate check — the token expires first, and
    /// expiry is the protection in that case. The rate check covers the other
    /// case: a quote that was already ageing on screen (up to `displayTolerance`,
    /// 90s) before the user confirmed it.
    func testStaleExchangeRateIsRejectedAtSpendTime() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)

        // The sheet sat open long enough for the price to be stale, and only
        // then did the user confirm.
        harness.clock.advance(by: RateFreshness.spendTolerance + 10)
        let authorized = try await authorize(harness, quote: quote)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected a stale-rate rejection")
        } catch PaymentEngineError.rateStale {
            let sends = await harness.backend.recordedSends()
            XCTAssertTrue(sends.isEmpty, "nothing may be spent against a stale price")
        }
    }

    /// The complementary case, which documents why the two tolerances differ:
    /// a quote confirmed while fresh is protected by approval expiry rather
    /// than by the rate check.
    func testApprovalExpiryCoversAQuoteThatWasFreshWhenConfirmed() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        let authorized = try await authorize(harness, quote: quote)

        harness.clock.advance(by: AuthorizationGate.approvalValidity + 1)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected the approval to have expired")
        } catch PaymentEngineError.intentExpired {
            let sends = await harness.backend.recordedSends()
            XCTAssertTrue(sends.isEmpty)
        }
    }

    // MARK: - Gates are re-evaluated at spend time, not only at render time

    func testCapIsRecheckedBetweenApprovalAndSpend() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        let authorized = try await authorize(harness, quote: quote)

        // The user tips from the host app while the share sheet sits open.
        for _ in 0..<5 { await harness.capLedger.record(spent: .gbp(pence: 2_000)) }

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected the daily cap to bind")
        } catch PaymentEngineError.capExceeded {
            let sends = await harness.backend.recordedSends()
            XCTAssertTrue(sends.isEmpty)
        }
    }

    func testRateLimitIsRecheckedBetweenApprovalAndSpend() async throws {
        let harness = makeHarness()
        let creator = CreatorRecord.stub()
        let quote = try await makeQuote(harness, creator: creator)
        let authorized = try await authorize(harness, quote: quote, creator: creator)

        for _ in 0..<3 { await harness.rateLimiter.record(handleKey: creator.handle.registryKey) }

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected the rate limiter to bind")
        } catch PaymentEngineError.rateLimited {
            let sends = await harness.backend.recordedSends()
            XCTAssertTrue(sends.isEmpty)
        }
    }

    func testInsufficientFundsIsCaughtBeforeSending() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        let authorized = try await authorize(harness, quote: quote)

        await harness.backend.setBalance(100, for: .bitcoin)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected an insufficient-funds rejection")
        } catch PaymentEngineError.insufficientFunds(let available, let required) {
            XCTAssertEqual(available, .sats(100))
            XCTAssertEqual(required, .sats(2_060))
            let sends = await harness.backend.recordedSends()
            XCTAssertTrue(sends.isEmpty)
        }
    }

    /// A failing payment still consumes a rate-limit slot, otherwise a caller
    /// could retry indefinitely and never trip the limiter.
    func testFailedPaymentStillConsumesARateLimitSlot() async throws {
        let harness = makeHarness()
        let creator = CreatorRecord.stub()
        await harness.backend.failSends(to: creator.lightningAddress, with: .network("no route"))

        let quote = try await makeQuote(harness, creator: creator)
        _ = try? await harness.engine.execute(try await authorize(harness, quote: quote, creator: creator))

        let decision = await harness.rateLimiter.evaluate(handleKey: creator.handle.registryKey)
        XCTAssertTrue(decision.isAllowed, "one attempt of three")

        for _ in 0..<2 { await harness.rateLimiter.record(handleKey: creator.handle.registryKey) }
        let afterThree = await harness.rateLimiter.evaluate(handleKey: creator.handle.registryKey)
        XCTAssertFalse(afterThree.isAllowed)
    }

    // MARK: - Cross-asset settlement

    /// Sender spends USDT, creator has chosen to receive Bitcoin.
    func testCrossAssetTipConvertsInFlight() async throws {
        let harness = makeHarness()
        // 1 USDT cent -> 25 sats, plus a 2-cent conversion cost.
        await harness.backend.setConversion(rate: 25.0, cost: 2)

        let creator = CreatorRecord.stub(preferredAsset: .bitcoin)
        let tip = Amount.usdtCents(100)
        let quote = try await makeQuote(harness, tip: tip, creator: creator)

        XCTAssertTrue(quote.route.requiresConversion)
        XCTAssertEqual(quote.route.debited, .usdtCents(100))
        XCTAssertEqual(quote.route.credited, .sats(2_500))
        XCTAssertEqual(quote.fee, .usdtCents(3), "our fee is charged in the sender's asset")
        XCTAssertEqual(quote.senderPays, .usdtCents(105), "tip + conversion cost + fee")
        XCTAssertEqual(quote.conversionDisclosure, "1.00 USDT converted to 2,500 sats")

        _ = try await harness.engine.execute(try await authorize(harness, quote: quote, creator: creator))
        let sends = await harness.backend.recordedSends()
        XCTAssertEqual(sends[0].route.credited, .sats(2_500))
    }

    func testSameAssetTipNeedsNoConversion() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness, creator: .stub(preferredAsset: .bitcoin))
        XCTAssertFalse(quote.route.requiresConversion)
        XCTAssertEqual(quote.route.conversionCost, .sats(0))
        XCTAssertNil(quote.conversionDisclosure)
    }

    // MARK: - Audit trail

    func testEveryPaymentLeavesACompleteAuditTrail() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        _ = try await harness.engine.execute(try await authorize(harness, quote: quote))

        let stages = await harness.audit.stages()
        for expected: AuditEvent.Stage in [.authorizationRequested, .authorizationGranted,
                                           .capsEvaluated, .rateLimitEvaluated,
                                           .tipPaymentAttempted, .tipPaymentSucceeded,
                                           .feePaymentAttempted, .feePaymentSucceeded, .settled] {
            XCTAssertTrue(stages.contains(expected), "missing \(expected) from the audit trail")
        }
    }

    func testRejectedPaymentsAreAuditedToo() async throws {
        let harness = makeHarness()
        let quote = try await makeQuote(harness)
        let authorized = try await authorize(harness, quote: quote)
        harness.clock.advance(by: AuthorizationGate.approvalValidity + 1)

        _ = try? await harness.engine.execute(authorized)

        let events = await harness.audit.events
        XCTAssertTrue(events.contains { $0.outcome == .rejected },
                      "a refused payment must be as visible in the log as a successful one")
    }
}
