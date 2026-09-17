import Foundation

public enum LightningDepositState: Equatable, Sendable {
    case idle
    case creating
    case awaitingPayment(paymentRequest: String, paymentHash: String, amountSats: Int64)
    case checking(paymentRequest: String, paymentHash: String, amountSats: Int64)
    case completed(balances: [Asset: Int64])
    case failed(String)
}

/// Drives a real Lightning deposit: create an invoice, let the human pay it
/// from any wallet, then poll the registry to find out when it settles and
/// the custodial ledger credits.
///
/// No biometric gate here, unlike every send-shaped flow in this app --
/// receiving money never needs proof the human authorised it, only spending
/// does.
public actor LightningDepositFlow {
    private let backend: CustodialPaymentBackend

    public init(backend: CustodialPaymentBackend) {
        self.backend = backend
    }

    public func create(amountSats: Int64) async -> LightningDepositState {
        do {
            let invoice = try await backend.createLightningDeposit(amountSats: amountSats)
            return .awaitingPayment(paymentRequest: invoice.paymentRequest,
                                    paymentHash: invoice.paymentHash, amountSats: invoice.amountSats)
        } catch let error as PaymentBackendError {
            return .failed(TipFlow.describe(error))
        } catch {
            return .failed("Couldn't create that invoice. Try again.")
        }
    }

    public func checkStatus(paymentHash: String, paymentRequest: String, amountSats: Int64) async -> LightningDepositState {
        do {
            let result = try await backend.checkLightningDeposit(paymentHash: paymentHash)
            if result.completed {
                return .completed(balances: result.balances)
            }
            return .awaitingPayment(paymentRequest: paymentRequest, paymentHash: paymentHash, amountSats: amountSats)
        } catch let error as PaymentBackendError {
            return .failed(TipFlow.describe(error))
        } catch {
            return .failed("Couldn't check that deposit. Try again.")
        }
    }
}
