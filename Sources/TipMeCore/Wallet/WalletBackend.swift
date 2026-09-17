import Foundation

public enum ReceiveMethod: String, CaseIterable, Sendable {
    case lightning
    case bitcoin
    case liquid
}

public struct ReceiveRequest: Equatable, Sendable {
    public let method: ReceiveMethod
    /// Invoice or address the sender pays.
    public let destination: String
    public let feeSat: Int64
    public let minimum: Amount?
    public let maximum: Amount?

    public init(method: ReceiveMethod, destination: String, feeSat: Int64,
                minimum: Amount?, maximum: Amount?) {
        self.method = method
        self.destination = destination
        self.feeSat = feeSat
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// General-purpose wallet operations: send to anything, receive, read history.
///
/// Separate from `PaymentBackend`, which stays narrowly scoped to LNURL-pay tip
/// settlement. This protocol is what makes TipMe a wallet rather than a tip
/// jar — sending to a raw invoice or an on-chain address, not just a
/// registered creator's Lightning address.
///
/// A `WalletBackend` implementation is expected to also implement
/// `PaymentBackend`; `CustodialPaymentBackend` does both, since the wallet
/// is one thing underneath.
public protocol WalletBackend: Sendable {
    /// Spendable balance in a given asset, for a general send. Deliberately its
    /// own requirement rather than borrowed from `PaymentBackend` via a runtime
    /// cast — a `WalletBackend` must stand on its own, and `CustodialPaymentBackend`
    /// answers this identically to `PaymentBackend.availableBalance` since both
    /// read the same underlying ledger.
    func availableBalanceForSend(asset: Asset) async throws -> Amount

    /// Classifies raw pasted or scanned text. Throws rather than returning a
    /// best guess — sending to a misclassified destination is unrecoverable.
    func resolve(destination raw: String) async throws -> WalletDestination

    /// Prices a send to an already-resolved destination. Reuses
    /// `SettlementRoute` from the tipping path — the conversion mechanics are
    /// identical whether the money is going to a creator or to any invoice.
    func prepareSend(amount: Amount, to destination: WalletDestination) async throws -> SettlementRoute

    /// Executes a prepared send. `idempotencyKey` must be honoured, exactly as
    /// in `PaymentBackend.send` — a retry after an ambiguous failure must not
    /// pay twice.
    func send(route: SettlementRoute, to destination: WalletDestination,
             idempotencyKey: String) async throws -> PaymentReceipt

    /// Generates something for someone else to pay.
    func receive(amount: Amount?, method: ReceiveMethod) async throws -> ReceiveRequest

    /// Reads recent activity directly from the wallet backend. `TipFlow`'s
    /// audit log covers tips; this covers everything the underlying wallet
    /// itself settled, which is the superset the Activity screen actually
    /// needs.
    func transactionHistory(limit: Int) async throws -> [WalletTransaction]
}
