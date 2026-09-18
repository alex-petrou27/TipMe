import Foundation

public enum OnChainDepositState: Equatable, Sendable {
    case idle
    case creating
    case awaitingPayment(address: String)
    case checking(address: String)
    case completed(balances: [Asset: Int64])
    case failed(String)
}

/// Drives a real on-chain Bitcoin deposit: issue a fresh address, let the
/// human send to it from any wallet, then poll the registry for a
/// confirmation. The on-chain sibling of `LightningDepositFlow` -- same
/// shape, no biometric gate (receiving never needs proof of authorisation),
/// but no fixed amount either: the sender decides how much to send, so
/// there is nothing to pass to `create()`.
public actor OnChainDepositFlow {
    private let backend: CustodialPaymentBackend

    public init(backend: CustodialPaymentBackend) {
        self.backend = backend
    }

    public func create() async -> OnChainDepositState {
        do {
            let address = try await backend.createOnChainDeposit()
            return .awaitingPayment(address: address)
        } catch let error as PaymentBackendError {
            return .failed(TipFlow.describe(error))
        } catch {
            return .failed("Couldn't create that address. Try again.")
        }
    }

    public func checkStatus(address: String) async -> OnChainDepositState {
        do {
            let result = try await backend.checkOnChainDeposit(address: address)
            if result.completed {
                return .completed(balances: result.balances)
            }
            return .awaitingPayment(address: address)
        } catch let error as PaymentBackendError {
            return .failed(TipFlow.describe(error))
        } catch {
            return .failed("Couldn't check that deposit. Try again.")
        }
    }
}
