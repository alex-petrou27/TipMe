import Foundation

public enum ApplePayDepositState: Equatable, Sendable {
    case idle
    case paying
    case completed(balances: [Asset: Int64])
    case failed(String)
}

/// Drives a dummy Apple Pay top-up: one call, immediately credited -- see
/// `CustodialPaymentBackend.depositApplePay` and the registry's
/// `deposit_apple_pay` docstring for why there is no real charge behind this
/// yet and no "check" step to poll.
///
/// Presenting the actual Apple Pay sheet (`PKPaymentAuthorizationController`)
/// needs a view controller to present from, so it lives in the app target,
/// not here -- same boundary `LightningDepositFlow` draws around invoice
/// display. This flow only needs whatever `reference` the caller ends up
/// with: a real PKPayment transaction identifier when the sheet was shown
/// and authorised, or a locally generated one for the no-card test path.
public actor ApplePayDepositFlow {
    private let backend: CustodialPaymentBackend

    public init(backend: CustodialPaymentBackend) {
        self.backend = backend
    }

    public func pay(amountMinor: Int64, reference: String) async -> ApplePayDepositState {
        guard amountMinor > 0 else {
            return .failed("Enter an amount.")
        }
        do {
            let result = try await backend.depositApplePay(
                amount: .usdtCents(amountMinor), reference: reference)
            return .completed(balances: result.balances)
        } catch let error as PaymentBackendError {
            return .failed(TipFlow.describe(error))
        } catch {
            return .failed("Couldn't complete that deposit. Try again.")
        }
    }
}
