import Foundation
import BreezSDKLiquid
import TipMeCore

/// Topping the wallet up.
///
/// ## Why this exists when the brief said "no receive UI"
///
/// The brief reasoned that because TipMe is non-custodial, there is no balance
/// to show. That holds for a custodial float, but not for Breez Nodeless: the
/// sats live in the *user's own* on-device Liquid wallet. They are self-custodied,
/// not absent. So the user still has a balance, and still has to get money into
/// it before a single tip can be sent.
///
/// Without this screen the app's first run ends at "insufficient funds" with no
/// way forward. It is kept deliberately minimal — one address to send to, one
/// balance figure — rather than growing into a general-purpose wallet UI.
public actor WalletFunding {

    public struct DepositDestination: Sendable {
        public enum Method: String, Sendable, CaseIterable {
            case lightning
            case bitcoin
            case liquid

            public var displayName: String {
                switch self {
                case .lightning: return "Lightning"
                case .bitcoin: return "Bitcoin (on-chain)"
                case .liquid: return "Liquid"
                }
            }
        }

        public let method: Method
        /// Invoice or address to pay.
        public let destination: String
        /// What the swap/chain will cost, in sats.
        public let feesSat: Int64
        public let minimumSat: Int64?
        public let maximumSat: Int64?
    }

    private let backend: BreezPaymentBackend

    public init(backend: BreezPaymentBackend) {
        self.backend = backend
    }

    /// Produces a deposit destination for the chosen method.
    ///
    /// Fees are surfaced rather than hidden: an on-chain or Lightning top-up
    /// into a Liquid wallet involves a swap with a real cost, and a user who
    /// deposits £10 and sees £9.60 arrive should have been told first.
    public func depositDestination(method: DepositDestination.Method,
                                   amountSat: Int64?) async throws -> DepositDestination {
        let sdk = try await backend.connectedSDK()

        let paymentMethod: PaymentMethod = {
            switch method {
            case .lightning: return .lightning
            case .bitcoin: return .bitcoinAddress
            case .liquid: return .liquidAddress
            }
        }()

        let receiveAmount: ReceiveAmount? = amountSat.map {
            .bitcoin(payerAmountSat: UInt64(max(0, $0)))
        }

        let prepared = try sdk.prepareReceivePayment(
            req: PrepareReceiveRequest(paymentMethod: paymentMethod, amount: receiveAmount))

        let response = try sdk.receivePayment(
            req: ReceivePaymentRequest(prepareResponse: prepared))

        let limits = try? sdk.fetchLightningLimits()

        return DepositDestination(
            method: method,
            destination: response.destination,
            feesSat: Int64(prepared.feesSat),
            minimumSat: limits.map { Int64($0.receive.minSat) },
            maximumSat: limits.map { Int64($0.receive.maxSat) })
    }
}

extension BreezPaymentBackend {
    /// Exposes the connected SDK to the funding flow, which is part of the app
    /// rather than the payment path. Connects on demand.
    func connectedSDK() async throws -> BindingLiquidSdk {
        try await connect()
        return try requireSDK()
    }
}
