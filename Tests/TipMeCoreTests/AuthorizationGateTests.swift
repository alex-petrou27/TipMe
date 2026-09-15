import XCTest
@testable import TipMeCore

/// These tests exist to protect the single most important property in the
/// codebase: nothing reaches a spend without a present human.
final class AuthorizationGateTests: XCTestCase {

    private func makeIntent(clock: Clock) -> PaymentIntent {
        let creator = CreatorRecord.stub()
        let rate = AssetRate(asset: .bitcoin, currencyCode: "GBP",
                             scaledPricePerMinorUnit: 5_000_000, asOf: clock.now)
        let route = SettlementRoute.direct(.sats(2_000), at: clock.now)
        let quote = try! TipQuoteBuilder(feePolicy: .standard)
            .quote(tip: .sats(2_000), route: route, sendRate: rate)
        return PaymentIntent(quote: quote, creator: creator, sourceLink: nil,
                             origin: .shareExtension, createdAt: clock.now)
    }

    func testSuccessfulBiometricMintsASingleUseToken() async throws {
        let clock = MutableClock()
        let gate = AuthorizationGate(authorizer: FakeAuthorizer(), clock: clock,
                                     auditLog: InMemoryAuditLog())

        let first = try await gate.authorize(makeIntent(clock: clock))
        let second = try await gate.authorize(makeIntent(clock: clock))

        XCTAssertNotEqual(first.nonce, second.nonce, "each approval must be independently single-use")
        XCTAssertEqual(first.method, "faceID")
    }

    func testCancelledBiometricYieldsNoToken() async {
        let clock = MutableClock()
        let gate = AuthorizationGate(authorizer: FakeAuthorizer(.userCancelled), clock: clock,
                                     auditLog: InMemoryAuditLog())
        do {
            _ = try await gate.authorize(makeIntent(clock: clock))
            XCTFail("a cancelled biometric must not produce an authorization")
        } catch AuthorizationError.declined(let outcome) {
            XCTAssertEqual(outcome, .userCancelled)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testUnavailableBiometricsDoesNotFallThroughToApproval() async {
        let clock = MutableClock()
        let gate = AuthorizationGate(authorizer: FakeAuthorizer(.unavailable(reason: "no enrolled biometrics")),
                                     clock: clock, auditLog: InMemoryAuditLog())
        do {
            _ = try await gate.authorize(makeIntent(clock: clock))
            XCTFail("missing biometrics must fail closed, never open")
        } catch AuthorizationError.declined {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// The system biometric sheet should itself state what is being approved,
    /// so the user does not have to trust that our screen and our payment agree.
    func testPromptNamesTheCreatorAndTheExactTotal() async throws {
        let clock = MutableClock()
        let authorizer = RecordingAuthorizer()
        let gate = AuthorizationGate(authorizer: authorizer, clock: clock, auditLog: InMemoryAuditLog())

        _ = try await gate.authorize(makeIntent(clock: clock))

        let reasons = await authorizer.capturedReasons()
        let reason = try XCTUnwrap(reasons.first)
        XCTAssertTrue(reason.contains("£1.03"), "prompt must state the total charged, not the tip alone")
        XCTAssertTrue(reason.contains("@creator"))
    }

    func testTokenExpires() async throws {
        let clock = MutableClock()
        let gate = AuthorizationGate(authorizer: FakeAuthorizer(), clock: clock,
                                     auditLog: InMemoryAuditLog())

        let authorized = try await gate.authorize(makeIntent(clock: clock))
        XCTAssertFalse(authorized.isExpired(at: clock.now))

        clock.advance(by: AuthorizationGate.approvalValidity + 1)
        XCTAssertTrue(authorized.isExpired(at: clock.now))
    }

    func testBothGrantAndDenialAreAudited() async throws {
        let clock = MutableClock()

        let grantedLog = InMemoryAuditLog()
        _ = try await AuthorizationGate(authorizer: FakeAuthorizer(), clock: clock, auditLog: grantedLog)
            .authorize(makeIntent(clock: clock))
        let grantedStages = await grantedLog.stages()
        XCTAssertEqual(grantedStages, [.authorizationRequested, .authorizationGranted])

        let deniedLog = InMemoryAuditLog()
        _ = try? await AuthorizationGate(authorizer: FakeAuthorizer(.userCancelled), clock: clock, auditLog: deniedLog)
            .authorize(makeIntent(clock: clock))
        let deniedStages = await deniedLog.stages()
        XCTAssertEqual(deniedStages, [.authorizationRequested, .authorizationDenied])
    }

    /// # Compile-time guarantee
    ///
    /// `AuthorizedIntent`'s only initialiser is `private` to
    /// `AuthorizationGate.swift`. `PaymentEngine.execute` takes nothing else.
    /// Together that means there is no expressible way — from a model response,
    /// a URL, a push payload, a deep link, or any assistant layer added later —
    /// to reach a spend without the gate having run a live biometric check.
    ///
    /// Each line below is a compile error, which is exactly the point. If a
    /// future change makes any of them compile, this guarantee is gone and this
    /// comment is the warning that it mattered:
    ///
    ///     AuthorizedIntent(intent: i, authorizedAt: d, expiresAt: d, method: "x")
    ///     AuthorizedIntent.mint(intent: i, authorizedAt: d, validFor: 60, method: "x")
    ///
    /// Note that even the tests above cannot construct one directly; they all go
    /// through `gate.authorize`, the same path production uses.
    func testAuthorizedIntentCannotBeConstructedOutsideTheGate() async throws {
        let clock = MutableClock()
        let gate = AuthorizationGate(authorizer: FakeAuthorizer(), clock: clock,
                                     auditLog: InMemoryAuditLog())
        let authorized = try await gate.authorize(makeIntent(clock: clock))
        XCTAssertEqual(authorized.intent.origin, .shareExtension)
    }
}
