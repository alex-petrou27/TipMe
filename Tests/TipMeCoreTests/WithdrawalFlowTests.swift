import XCTest
@testable import TipMeCore

/// The shipped `UnavailableFiatOffRampProvider` must never report success. If
/// any of these ever fail because the provider started returning real data,
/// that is the signal a real banking partner needs its own review, not that
/// the test is stale.
final class UnavailableFiatOffRampProviderTests: XCTestCase {

    private let provider = UnavailableFiatOffRampProvider()

    func testReportsUnavailable() async {
        let available = await provider.isAvailable()
        XCTAssertFalse(available)
    }

    func testEveryOperationRefusesWithTheHonestReason() async {
        do {
            _ = try await provider.linkedBankAccounts()
            XCTFail("must not report any linked accounts")
        } catch FiatOffRampError.notAvailable(let reason) {
            XCTAssertTrue(reason.contains("licensed"))
        }

        do {
            _ = try await provider.linkBankAccount()
            XCTFail("must not link an account")
        } catch FiatOffRampError.notAvailable {}

        let account = BankAccount(id: "x", displayName: "Checking", currencyCode: "GBP", verified: true)
        do {
            _ = try await provider.quoteWithdrawal(amount: .sats(10_000), to: account)
            XCTFail("must not quote a withdrawal")
        } catch FiatOffRampError.notAvailable {}

        do {
            let fakeQuote = WithdrawalQuote(id: "q1", debited: .sats(10_000),
                                            fiatCredited: .gbp(pence: 500),
                                            exchangeRate: AssetRate(asset: .bitcoin, currencyCode: "GBP",
                                                                    scaledPricePerMinorUnit: 5_000_000, asOf: Date()),
                                            feeFiat: .gbp(pence: 0),
                                            estimatedArrival: DateComponents(day: 1), expiresAt: Date())
            _ = try await provider.executeWithdrawal(quote: fakeQuote, to: account)
            XCTFail("must never move money")
        } catch FiatOffRampError.notAvailable {}
    }
}

final class WithdrawalFlowTests: XCTestCase {

    private func makeFlow(provider: FiatOffRampProvider,
                          authorizer: BiometricAuthorizer = FakeAuthorizer()) -> (WithdrawalFlow, InMemoryAuditLog) {
        let clock = MutableClock()
        let audit = InMemoryAuditLog()
        let gate = AuthorizationGate(authorizer: authorizer, clock: clock, auditLog: audit)
        return (WithdrawalFlow(provider: provider, gate: gate, auditLog: audit, clock: clock), audit)
    }

    // MARK: - The shipped, honest state

    func testStartWithTheShippedProviderIsUnavailable() async {
        let (flow, audit) = makeFlow(provider: UnavailableFiatOffRampProvider())
        let state = await flow.start()

        guard case .unavailable(let reason) = state else {
            return XCTFail("expected unavailable, got \(state)")
        }
        XCTAssertTrue(reason.contains("licensed"))

        let stages = await audit.stages()
        XCTAssertTrue(stages.contains(.withdrawalUnavailable),
                      "a refused withdrawal path must still leave an audit trail")
    }

    // MARK: - A hypothetical real provider, to prove the architecture works

    func testStartWithNoLinkedAccountPromptsToLink() async {
        let provider = FakeOffRampProvider()
        await provider.setAvailable(true)
        let (flow, _) = makeFlow(provider: provider)

        let state = await flow.start()
        guard case .noBankLinked = state else { return XCTFail("expected noBankLinked, got \(state)") }
    }

    func testLinkingThenQuotingThenWithdrawing() async throws {
        let provider = FakeOffRampProvider()
        await provider.setAvailable(true)
        let (flow, audit) = makeFlow(provider: provider)

        guard case .noBankLinked = await flow.start() else { return XCTFail("setup failed") }
        guard case .ready(let account) = await flow.linkAccount() else { return XCTFail("link failed") }

        let quote = WithdrawalQuote(id: "q1", debited: .sats(100_000), fiatCredited: .gbp(pence: 5_000),
                                    exchangeRate: AssetRate(asset: .bitcoin, currencyCode: "GBP",
                                                            scaledPricePerMinorUnit: 5_000_000, asOf: Date()),
                                    feeFiat: .gbp(pence: 50), estimatedArrival: DateComponents(day: 1),
                                    expiresAt: Date().addingTimeInterval(300))
        await provider.setQuote(quote)

        guard case .quoted(let returnedQuote, _) = await flow.quote(amount: .sats(100_000), account: account) else {
            return XCTFail("quote failed")
        }

        let result = await flow.confirmAndWithdraw(quote: returnedQuote, account: account)
        guard case .succeeded(let receipt) = result else { return XCTFail("withdraw failed: \(result)") }
        XCTAssertEqual(receipt.fiatCredited, .gbp(pence: 5_000))

        let stages = await audit.stages()
        XCTAssertTrue(stages.contains(.withdrawalRequested))
        XCTAssertTrue(stages.contains(.withdrawalSucceeded))
    }

    /// Withdrawing your own money to your own bank account is still a spend,
    /// so it is still gated — the shipped provider being unavailable is not
    /// why Face ID is required here; it would be required even if a real
    /// partner were connected.
    func testWithdrawalIsStillGatedByBiometrics() async {
        let provider = FakeOffRampProvider()
        await provider.setAvailable(true)
        let (flow, _) = makeFlow(provider: provider, authorizer: FakeAuthorizer(.userCancelled))

        _ = await flow.start()
        guard case .ready(let account) = await flow.linkAccount() else { return XCTFail("link failed") }

        let quote = WithdrawalQuote(id: "q1", debited: .sats(100_000), fiatCredited: .gbp(pence: 5_000),
                                    exchangeRate: AssetRate(asset: .bitcoin, currencyCode: "GBP",
                                                            scaledPricePerMinorUnit: 5_000_000, asOf: Date()),
                                    feeFiat: .gbp(pence: 50), estimatedArrival: DateComponents(day: 1),
                                    expiresAt: Date().addingTimeInterval(300))

        let result = await flow.confirmAndWithdraw(quote: quote, account: account)
        guard case .quoted = result else {
            return XCTFail("a cancelled biometric must return to the quote, not proceed")
        }
    }
}
