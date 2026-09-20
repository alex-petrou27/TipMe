import Foundation
@testable import TipMeCore

// MARK: - Payment backend

/// Scriptable wallet. Records every send so tests can assert on the *order* of
/// the two payments, which is the property that guarantees a creator is paid
/// before we take a fee.
actor FakePaymentBackend: PaymentBackend {
    struct SendCall: Equatable {
        let destination: LightningAddress
        let route: SettlementRoute
        let idempotencyKey: String
    }

    struct LinkedAccountSendCall: Equatable {
        let handle: CreatorHandle
        let amount: Amount
        let idempotencyKey: String
    }

    var balances: [Asset: Int64]
    var rates: [Asset: AssetRate]
    var sendCalls: [SendCall] = []
    var linkedAccountSendCalls: [LinkedAccountSendCall] = []
    /// Destinations that should fail, keyed by lightning address string.
    var failingDestinations: [String: PaymentBackendError] = [:]
    var linkedAccountSendError: PaymentBackendError?
    var conversionRate: Double = 1.0
    var conversionCostMinorUnits: Int64 = 0
    var prepareRouteError: PaymentBackendError?
    private let clock: Clock

    init(clock: Clock, balances: [Asset: Int64] = [.bitcoin: 1_000_000, .usdt: 100_000]) {
        self.clock = clock
        self.balances = balances
        self.rates = [
            // BTC at £50,000 => one sat is 0.05p => 0.05 * 1e8 scaled.
            .bitcoin: AssetRate(asset: .bitcoin, currencyCode: "GBP",
                                scaledPricePerMinorUnit: 5_000_000, asOf: clock.now),
            // USDT at £0.80 => one cent is 0.8p => 0.8 * 1e8 scaled.
            .usdt: AssetRate(asset: .usdt, currencyCode: "GBP",
                             scaledPricePerMinorUnit: 80_000_000, asOf: clock.now)
        ]
    }

    func setBalance(_ value: Int64, for asset: Asset) { balances[asset] = value }
    func setRate(_ rate: AssetRate) { rates[rate.asset] = rate }
    func failSends(to address: LightningAddress, with error: PaymentBackendError) {
        failingDestinations[address.description] = error
    }
    func setPrepareRouteError(_ error: PaymentBackendError?) { prepareRouteError = error }
    func setConversion(rate: Double, cost: Int64) {
        conversionRate = rate
        conversionCostMinorUnits = cost
    }

    func availableBalance(for asset: Asset) async throws -> Amount {
        Amount(asset: asset, minorUnits: balances[asset] ?? 0)
    }

    func rate(for asset: Asset, in currencyCode: String) async throws -> AssetRate {
        guard let rate = rates[asset], rate.currencyCode == currencyCode.uppercased() else {
            throw ExchangeRateError.unavailable(asset: asset, currencyCode: currencyCode)
        }
        return rate
    }

    func prepareRoute(tip: Amount, to destination: LightningAddress,
                      receiveAsset: Asset) async throws -> SettlementRoute {
        if let error = prepareRouteError { throw error }
        guard tip.asset != receiveAsset else {
            return .direct(tip, at: clock.now)
        }
        let credited = Amount(asset: receiveAsset,
                              minorUnits: Int64(Double(tip.minorUnits) * conversionRate))
        return SettlementRoute(sendAsset: tip.asset,
                               receiveAsset: receiveAsset,
                               debited: tip,
                               credited: credited,
                               conversionCost: Amount(asset: tip.asset,
                                                      minorUnits: conversionCostMinorUnits),
                               quotedAt: clock.now)
    }

    func send(route: SettlementRoute, to destination: LightningAddress,
              idempotencyKey: String) async throws -> PaymentReceipt {
        sendCalls.append(SendCall(destination: destination, route: route, idempotencyKey: idempotencyKey))
        if let error = failingDestinations[destination.description] { throw error }
        return PaymentReceipt(status: .succeeded,
                              paymentHash: "hash-\(sendCalls.count)",
                              networkFee: .zero(route.sendAsset),
                              sentAmount: route.debited,
                              completedAt: clock.now)
    }

    func recordedSends() -> [SendCall] { sendCalls }

    func setLinkedAccountSendError(_ error: PaymentBackendError?) { linkedAccountSendError = error }

    func sendToCreatorAccount(handle: CreatorHandle, amount: Amount,
                              idempotencyKey: String) async throws -> PaymentReceipt {
        linkedAccountSendCalls.append(LinkedAccountSendCall(handle: handle, amount: amount, idempotencyKey: idempotencyKey))
        if let error = linkedAccountSendError { throw error }
        return PaymentReceipt(status: .succeeded,
                              paymentHash: "ledger-\(linkedAccountSendCalls.count)",
                              networkFee: .zero(amount.asset),
                              sentAmount: amount,
                              completedAt: clock.now)
    }
}

// MARK: - Biometrics

/// Stands in for Face ID. Note there is no way to construct an
/// `AuthorizedIntent` without going through `AuthorizationGate` — even here, in
/// the tests. That is the point of the design, so the tests exercise the same
/// path production does.
struct FakeAuthorizer: BiometricAuthorizer {
    let outcome: BiometricOutcome
    init(_ outcome: BiometricOutcome = .succeeded(method: "faceID")) { self.outcome = outcome }
    func evaluate(reason: String) async -> BiometricOutcome { outcome }
}

/// Captures the prompt string so we can assert the biometric sheet itself
/// states the amount, rather than relying on our own UI to be honest.
actor RecordingAuthorizer: BiometricAuthorizer {
    private(set) var reasons: [String] = []
    let outcome: BiometricOutcome
    init(_ outcome: BiometricOutcome = .succeeded(method: "faceID")) { self.outcome = outcome }
    func evaluate(reason: String) async -> BiometricOutcome {
        reasons.append(reason)
        return outcome
    }
    func capturedReasons() -> [String] { reasons }
}

// MARK: - Creator directory

struct FakeCreatorResolver: CreatorResolver {
    var records: [CreatorHandle: CreatorRecord] = [:]
    var error: CreatorLookupError?

    func resolve(_ handle: CreatorHandle) async throws -> CreatorRecord {
        if let error { throw error }
        guard let record = records[handle] else { throw CreatorLookupError.notRegistered(handle) }
        return record
    }
}

// MARK: - Convenience builders

extension CreatorRecord {
    static func stub(username: String = "creator",
                     platform: Platform = .tiktok,
                     address: String = "creator@getalby.com",
                     preferredAsset: Asset = .bitcoin,
                     minimum: Int64? = nil,
                     verified: Bool = true,
                     tipmeLinked: Bool = false,
                     at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CreatorRecord {
        CreatorRecord(handle: CreatorHandle(platform: platform, rawUsername: username)!,
                      lightningAddress: LightningAddress(address)!,
                      preferredAsset: preferredAsset,
                      minimumTipMinorUnits: minimum,
                      updatedAt: date,
                      displayName: username,
                      verified: verified,
                      tipmeLinked: tipmeLinked)
    }
}

enum Fixtures {
    static let feeDestination = LightningAddress("fees@tipme.example")!

    /// £1.00 at the fake backend's rate is 2000 sats.
    static let onePoundInSats: Int64 = 2_000
}
