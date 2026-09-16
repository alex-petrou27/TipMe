import Foundation
@testable import TipMeCore

/// Scriptable general-purpose wallet backend, mirroring `FakePaymentBackend`
/// but for the "send to anything" surface.
actor FakeWalletBackend: WalletBackend, PaymentBackend {
    var balances: [Asset: Int64]
    var rates: [Asset: AssetRate]
    var resolved: [String: WalletDestination] = [:]
    var sendCalls: [(destination: WalletDestination, route: SettlementRoute, key: String)] = []
    var failNextSend: PaymentBackendError?
    var history: [WalletTransaction] = []
    private let clock: Clock

    init(clock: Clock, balances: [Asset: Int64] = [.bitcoin: 1_000_000, .usdt: 100_000]) {
        self.clock = clock
        self.balances = balances
        self.rates = [
            .bitcoin: AssetRate(asset: .bitcoin, currencyCode: "GBP",
                                scaledPricePerMinorUnit: 5_000_000, asOf: clock.now),
            .usdt: AssetRate(asset: .usdt, currencyCode: "GBP",
                             scaledPricePerMinorUnit: 80_000_000, asOf: clock.now)
        ]
    }

    func stubResolution(_ raw: String, as destination: WalletDestination) { resolved[raw] = destination }
    func setBalance(_ value: Int64, for asset: Asset) { balances[asset] = value }

    // MARK: WalletBackend

    func availableBalanceForSend(asset: Asset) async throws -> Amount {
        Amount(asset: asset, minorUnits: balances[asset] ?? 0)
    }

    func resolve(destination raw: String) async throws -> WalletDestination {
        guard let destination = resolved[raw] else { throw WalletDestinationError.unrecognised }
        return destination
    }

    func prepareSend(amount: Amount, to destination: WalletDestination) async throws -> SettlementRoute {
        .direct(amount, at: clock.now)
    }

    func send(route: SettlementRoute, to destination: WalletDestination,
             idempotencyKey: String) async throws -> PaymentReceipt {
        sendCalls.append((destination, route, idempotencyKey))
        if let error = failNextSend { throw error }
        return PaymentReceipt(status: .succeeded, paymentHash: "wallet-hash-\(sendCalls.count)",
                              networkFee: .zero(route.sendAsset), sentAmount: route.debited,
                              completedAt: clock.now)
    }

    func receive(amount: Amount?, method: ReceiveMethod) async throws -> ReceiveRequest {
        ReceiveRequest(method: method, destination: "lnbc1testinvoice", feeSat: 0,
                      minimum: nil, maximum: nil)
    }

    func transactionHistory(limit: Int) async throws -> [WalletTransaction] {
        Array(history.prefix(limit))
    }

    // MARK: PaymentBackend (used by WalletSendFlow's ExchangeRateProvider cast)

    func availableBalance(for asset: Asset) async throws -> Amount {
        try await availableBalanceForSend(asset: asset)
    }

    func rate(for asset: Asset, in currencyCode: String) async throws -> AssetRate {
        guard let rate = rates[asset] else { throw ExchangeRateError.unavailable(asset: asset, currencyCode: currencyCode) }
        return rate
    }

    func prepareRoute(tip: Amount, to destination: LightningAddress, receiveAsset: Asset) async throws -> SettlementRoute {
        .direct(tip, at: clock.now)
    }

    /// The overload PaymentBackend itself requires (LightningAddress
    /// destination) — distinct from the WalletBackend overload above
    /// (WalletDestination). Unused by the wallet-send tests in this file, but
    /// required for conformance since FakeWalletBackend declares both
    /// protocols so WalletSendFlow's `backend as? ExchangeRateProvider` cast
    /// has something real to find.
    func send(route: SettlementRoute, to destination: LightningAddress,
             idempotencyKey: String) async throws -> PaymentReceipt {
        PaymentReceipt(status: .succeeded, paymentHash: "lnurl-hash",
                       networkFee: .zero(route.sendAsset), sentAmount: route.debited,
                       completedAt: clock.now)
    }
}

enum WalletFixtures {
    static let feeDestination = LightningAddress("fees@tipme.example")!
}

/// Scriptable off-ramp for exercising `WithdrawalFlow` beyond the shipped
/// always-refuse provider.
actor FakeOffRampProvider: FiatOffRampProvider {
    private var available = false
    private var accounts: [BankAccount] = []
    private var quoteToReturn: WithdrawalQuote?
    private var withdrawalError: FiatOffRampError?

    // Actor-isolated state can only be mutated from outside through an async
    // method — there is no "await instance.property = value" for cross-actor
    // writes — so the test harness gets explicit setters rather than exposed
    // vars.
    func setAvailable(_ value: Bool) { available = value }
    func setQuote(_ quote: WithdrawalQuote) { quoteToReturn = quote }
    func setWithdrawalError(_ error: FiatOffRampError) { withdrawalError = error }

    func isAvailable() async -> Bool { available }

    func linkedBankAccounts() async throws -> [BankAccount] {
        guard available else { throw FiatOffRampError.notAvailable(reason: "not available in test") }
        return accounts
    }

    func linkBankAccount() async throws -> BankAccount {
        let account = BankAccount(id: "acc-1", displayName: "Checking ····4821",
                                  currencyCode: "GBP", verified: true)
        accounts.append(account)
        return account
    }

    func quoteWithdrawal(amount: Amount, to account: BankAccount) async throws -> WithdrawalQuote {
        if let quoteToReturn { return quoteToReturn }
        throw FiatOffRampError.notAvailable(reason: "no quote stubbed")
    }

    func executeWithdrawal(quote: WithdrawalQuote, to account: BankAccount) async throws -> WithdrawalReceipt {
        if let withdrawalError { throw withdrawalError }
        return WithdrawalReceipt(id: quote.id, status: "submitted", fiatCredited: quote.fiatCredited,
                                 bankAccount: account, submittedAt: Date())
    }
}
