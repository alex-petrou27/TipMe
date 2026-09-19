import PassKit

/// The one piece of real Apple Pay setup this codebase cannot supply by
/// itself: a merchant identifier registered at developer.apple.com,
/// matching the one named in `TipMe.entitlements` under
/// `com.apple.developer.in-app-payments`. Replace both together -- a
/// mismatch between them is a silent failure at authorization time, not a
/// build error.
enum ApplePayConfiguration {
    static let merchantIdentifier = "merchant.com.tipme.app"
    static let merchantCountryCode = "US"
    static let supportedNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .amex]
}

/// Bridges PassKit's delegate-based sheet to async/await for `DepositView`.
///
/// `canPay()` reflects only whether the device has cards in Wallet that
/// support one of `supportedNetworks` -- it says nothing about whether
/// `ApplePayConfiguration.merchantIdentifier` is a real, registered
/// merchant ID. Until it is, the sheet can appear and still fail to
/// authorize; `DepositViewModel` falls back to a no-card test deposit
/// either way `requestPayment` returns `nil`.
@MainActor
final class ApplePayAuthorizer: NSObject, PKPaymentAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<PKPayment?, Never>?
    private var didAuthorize = false

    static func canPay() -> Bool {
        PKPaymentAuthorizationController.canMakePayments(usingNetworks: ApplePayConfiguration.supportedNetworks)
    }

    /// Presents the Apple Pay sheet for `amount` (major units, e.g. dollars)
    /// and suspends until the person authorizes, cancels, or the sheet
    /// fails to present at all -- all three return `nil` except a genuine
    /// authorization, so the caller only has one success path to handle.
    func requestPayment(amount: Decimal, currencyCode: String, label: String) async -> PKPayment? {
        let request = PKPaymentRequest()
        request.merchantIdentifier = ApplePayConfiguration.merchantIdentifier
        request.countryCode = ApplePayConfiguration.merchantCountryCode
        request.currencyCode = currencyCode
        request.supportedNetworks = ApplePayConfiguration.supportedNetworks
        request.merchantCapabilities = .threeDSecure
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(label: label, amount: NSDecimalNumber(decimal: amount)),
        ]

        let controller = PKPaymentAuthorizationController(paymentRequest: request)
        controller.delegate = self
        didAuthorize = false

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.present { presented in
                if !presented {
                    self.continuation?.resume(returning: nil)
                    self.continuation = nil
                }
            }
        }
    }

    func paymentAuthorizationController(_ controller: PKPaymentAuthorizationController,
                                        didAuthorizePayment payment: PKPayment,
                                        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void) {
        didAuthorize = true
        // There is no processor behind this yet to actually decrypt/charge
        // the token -- see DepositViewModel and the registry's
        // deposit_apple_pay docstring. Reporting success here is what makes
        // PassKit dismiss the sheet normally; the ledger credit itself
        // happens afterwards, off `payment.token.transactionIdentifier`.
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
        continuation?.resume(returning: payment)
        continuation = nil
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss { [weak self] in
            guard let self, !self.didAuthorize else { return }
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }
}
