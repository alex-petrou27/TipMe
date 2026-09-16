import XCTest
@testable import TipMeCore

final class WalletSendEngineTests: XCTestCase {

    private struct Harness {
        let clock: MutableClock
        let backend: FakeWalletBackend
        let engine: WalletSendEngine
        let gate: AuthorizationGate
        let flow: WalletSendFlow
        let audit: InMemoryAuditLog
        let capLedger: SendCapLedger
    }

    private func makeHarness(authorizer: BiometricAuthorizer = FakeAuthorizer(),
                             capPolicy: SendCapPolicy = .standard) -> Harness {
        let clock = MutableClock()
        let backend = FakeWalletBackend(clock: clock)
        let audit = InMemoryAuditLog()
        let store = InMemoryKeyValueStore()
        // Distinct namespace from the tipping ledger — this is the property
        // under test in a couple of cases below.
        let capLedger = SendCapLedger(store: store, clock: clock, policy: capPolicy, namespace: "wallet")
        let gate = AuthorizationGate(authorizer: authorizer, clock: clock, auditLog: audit)
        let engine = WalletSendEngine(backend: backend, capLedger: capLedger, auditLog: audit, clock: clock)
        return Harness(clock: clock, backend: backend, engine: engine, gate: gate,
                       flow: WalletSendFlow(backend: backend, gate: gate, engine: engine, clock: clock),
                       audit: audit, capLedger: capLedger)
    }

    private func authorize(_ harness: Harness, amount: Amount,
                           destination: WalletDestination) async throws -> AuthorizedWalletSend {
        let route = SettlementRoute.direct(amount, at: harness.clock.now)
        let rate = try await harness.backend.rate(for: amount.asset, in: "GBP")
        let intent = WalletSendIntent(destination: destination, amount: amount, route: route,
                                      fiatAmount: rate.fiatValue(of: amount),
                                      rateAsOf: harness.clock.now, createdAt: harness.clock.now)
        return try await harness.gate.authorize(intent, reason: "Send \(amount.formatted)")
    }

    // MARK: - Happy path

    func testSendToAnOnChainAddressSucceeds() async throws {
        let harness = makeHarness()
        let destination = WalletDestination.bitcoinAddress(raw: "bc1qxyz")

        let authorized = try await authorize(harness, amount: .sats(50_000), destination: destination)
        let result = try await harness.engine.execute(authorized)

        XCTAssertEqual(result.receipt.status, .succeeded)
        let calls = await harness.backend.sendCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].destination, destination)
    }

    func testSendToALightningInvoiceSucceeds() async throws {
        let harness = makeHarness()
        let destination = WalletDestination.lightningInvoice(raw: "lnbc1...", amountSat: 10_000, description: "coffee")

        let authorized = try await authorize(harness, amount: .sats(10_000), destination: destination)
        _ = try await harness.engine.execute(authorized)

        let calls = await harness.backend.sendCalls
        XCTAssertEqual(calls[0].destination, destination)
    }

    // MARK: - The same guarantees PaymentEngine has, exercised here too

    func testReplayIsRejected() async throws {
        let harness = makeHarness()
        let authorized = try await authorize(harness, amount: .sats(1_000),
                                             destination: .bitcoinAddress(raw: "bc1qxyz"))
        _ = try await harness.engine.execute(authorized)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("a single-use token was accepted twice")
        } catch WalletSendError.intentAlreadyExecuted {
            let calls = await harness.backend.sendCalls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testExpiredAuthorizationIsRejected() async throws {
        let harness = makeHarness()
        let authorized = try await authorize(harness, amount: .sats(1_000),
                                             destination: .bitcoinAddress(raw: "bc1qxyz"))
        harness.clock.advance(by: AuthorizationGate.approvalValidity + 1)

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected expiry")
        } catch WalletSendError.intentExpired {
            let calls = await harness.backend.sendCalls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testInsufficientFundsIsCaughtBeforeSending() async throws {
        let harness = makeHarness()
        await harness.backend.setBalance(100, for: .bitcoin)
        let authorized = try await authorize(harness, amount: .sats(50_000),
                                             destination: .bitcoinAddress(raw: "bc1qxyz"))

        do {
            _ = try await harness.engine.execute(authorized)
            XCTFail("expected insufficient funds")
        } catch WalletSendError.insufficientFunds {
            let calls = await harness.backend.sendCalls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testCancelledBiometricProducesNoAuthorization() async {
        let harness = makeHarness(authorizer: FakeAuthorizer(.userCancelled))
        do {
            _ = try await authorize(harness, amount: .sats(1_000), destination: .bitcoinAddress(raw: "bc1qxyz"))
            XCTFail("a cancelled biometric must not authorise a send")
        } catch AuthorizationError.declined(let outcome) {
            XCTAssertEqual(outcome, .userCancelled)
        }
    }

    /// The property namespacing exists for: a big legitimate wallet send must
    /// not be blocked by — and must not deplete — the tipping cap, and vice
    /// versa.
    func testWalletSendCapIsIndependentOfTheTippingCap() async throws {
        let clock = MutableClock()
        let store = InMemoryKeyValueStore()
        let tipLedger = SendCapLedger(store: store, clock: clock, namespace: "tips")
        let walletLedger = SendCapLedger(store: store, clock: clock, namespace: "wallet")

        for _ in 0..<5 { await tipLedger.record(spent: .gbp(pence: 2_000)) } // tips maxed out

        let walletDecision = await walletLedger.evaluate(requested: .gbp(pence: 100))
        XCTAssertTrue(walletDecision.isAllowed, "wallet spending must not share the tipping ledger")
    }

    /// £1.00 daily cap; each send is exactly £1.00 (2,000 sats at the fake
    /// backend's rate). The first fills the day's budget exactly and must
    /// succeed; the second must be refused before anything is sent.
    func testWalletSendRespectsItsOwnCap() async throws {
        let harness = makeHarness(capPolicy: SendCapPolicy(perTip: 100, perDay: 100, perWeek: 100))
        let destination = WalletDestination.bitcoinAddress(raw: "bc1qxyz")

        let first = try await authorize(harness, amount: .sats(2_000), destination: destination)
        _ = try await harness.engine.execute(first)

        let second = try await authorize(harness, amount: .sats(2_000), destination: destination)
        do {
            _ = try await harness.engine.execute(second)
            XCTFail("expected the daily wallet cap to bind on the second send")
        } catch WalletSendError.capExceeded {
            let calls = await harness.backend.sendCalls
            XCTAssertEqual(calls.count, 1, "only the first send should have reached the backend")
        }
    }

    func testEveryAttemptLeavesAnAuditTrail() async throws {
        let harness = makeHarness()
        let authorized = try await authorize(harness, amount: .sats(1_000), destination: .bitcoinAddress(raw: "bc1qxyz"))
        _ = try await harness.engine.execute(authorized)

        let stages = await harness.audit.stages()
        for expected: AuditEvent.Stage in [.authorizationRequested, .authorizationGranted,
                                           .walletSendAttempted, .walletSendSucceeded] {
            XCTAssertTrue(stages.contains(expected), "missing \(expected)")
        }
    }

    // MARK: - Flow coordinator

    func testFlowIdentifiesAResolvableDestination() async throws {
        let harness = makeHarness()
        await harness.backend.stubResolution("bc1qxyz", as: .bitcoinAddress(raw: "bc1qxyz"))

        let state = await harness.flow.identify(pasted: "bc1qxyz")
        guard case .destinationFound(let destination) = state else {
            return XCTFail("expected destinationFound, got \(state)")
        }
        XCTAssertEqual(destination, .bitcoinAddress(raw: "bc1qxyz"))
    }

    func testFlowReportsAnUnresolvableDestination() async {
        let harness = makeHarness()
        let state = await harness.flow.identify(pasted: "not a real destination")
        guard case .unrecognised = state else {
            return XCTFail("expected unrecognised, got \(state)")
        }
    }

    func testFlowEndToEnd() async throws {
        let harness = makeHarness()
        let destination = WalletDestination.bitcoinAddress(raw: "bc1qxyz")
        await harness.backend.stubResolution("bc1qxyz", as: destination)

        let identified = await harness.flow.identify(pasted: "bc1qxyz")
        guard case .destinationFound = identified else { return XCTFail("identify failed") }

        let quoted = await harness.flow.quote(amount: .sats(5_000), for: destination)
        guard case .quoted(_, _, let route, let fiat) = quoted else { return XCTFail("quote failed") }

        let sent = await harness.flow.confirmAndSend(destination: destination, amount: .sats(5_000),
                                                      route: route, fiatAmount: fiat)
        guard case .succeeded = sent else { return XCTFail("send failed: \(sent)") }
    }
}
