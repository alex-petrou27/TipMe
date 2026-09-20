import Foundation

public struct PaymentReceipt: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case succeeded
        /// Accepted by the network but not yet final. Liquid-side swaps can
        /// land here; the UI must not claim success until it settles.
        case pending
    }

    public let status: Status
    public let paymentHash: String
    /// Routing/network fee the backend actually paid, in the sent asset. This
    /// is the Lightning network's cost, not TipMe's fee.
    public let networkFee: Amount
    public let sentAmount: Amount
    public let completedAt: Date

    public init(status: Status, paymentHash: String, networkFee: Amount,
                sentAmount: Amount, completedAt: Date) {
        self.status = status
        self.paymentHash = paymentHash
        self.networkFee = networkFee
        self.sentAmount = sentAmount
        self.completedAt = completedAt
    }
}

public enum PaymentBackendError: Error, Equatable, Sendable {
    case notConnected
    case insufficientFunds(available: Amount, required: Amount)
    case destinationUnreachable(String)
    case amountBelowDestinationMinimum(minimum: Amount)
    case amountAboveDestinationMaximum(maximum: Amount)
    case conversionUnavailable(from: Asset, to: Asset)
    case routeExpired
    case network(String)
    case rejectedByNetwork(String)
}

/// The wallet seam.
///
/// `PaymentEngine` knows only this protocol, which is what makes the engine
/// reusable by the Phase 2 triggers and what makes a second implementation
/// an additive change rather than a rewrite. `CustodialPaymentBackend` in
/// this module is the current implementation, backed by TipMe's own
/// custodial ledger.
public protocol PaymentBackend: Sendable, ExchangeRateProvider {
    /// Spendable balance in a given asset.
    func availableBalance(for asset: Asset) async throws -> Amount

    /// Asks the backend what it would cost to deliver `tip` to `destination`
    /// in `receiveAsset`. For a same-asset payment this is a direct route; when
    /// the sender and creator differ, this carries the conversion terms.
    ///
    /// Also where the destination's own LNURL-pay min/max are discovered, so
    /// an out-of-range amount fails here rather than at spend time.
    func prepareRoute(tip: Amount,
                      to destination: LightningAddress,
                      receiveAsset: Asset) async throws -> SettlementRoute

    /// Executes a payment along a previously prepared route.
    ///
    /// `idempotencyKey` must be honoured: the engine derives it from the
    /// authorised intent, so a retry after an ambiguous network failure settles
    /// at most once. Paying twice because a response was lost is the single
    /// worst bug this system could have.
    func send(route: SettlementRoute,
              to destination: LightningAddress,
              idempotencyKey: String) async throws -> PaymentReceipt

    /// Executes a payment straight into a creator's TipMe ledger balance --
    /// no Lightning, no routing, no network beyond one call. Used instead of
    /// `send` when the creator's handle is linked to a TipMe account
    /// (`CreatorRecord.tipmeLinked`); see `PaymentEngine.execute`, which is
    /// what decides which of the two to call.
    ///
    /// The default implementation throws -- a backend only needs to
    /// implement this if it actually has a ledger to move money within, the
    /// same way most of this protocol's implementers never touch
    /// `WalletBackend`'s methods either.
    func sendToCreatorAccount(handle: CreatorHandle, amount: Amount,
                             idempotencyKey: String) async throws -> PaymentReceipt
}

public extension PaymentBackend {
    func sendToCreatorAccount(handle: CreatorHandle, amount: Amount,
                             idempotencyKey: String) async throws -> PaymentReceipt {
        throw PaymentBackendError.network("This backend has no linked-account ledger to tip into.")
    }
}
