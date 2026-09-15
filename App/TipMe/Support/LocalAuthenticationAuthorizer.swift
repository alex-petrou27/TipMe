import Foundation
import LocalAuthentication
import TipMeCore

/// Face ID / Touch ID via `LocalAuthentication`.
///
/// Two deliberate choices:
///
/// 1. `.deviceOwnerAuthentication`, not `.deviceOwnerAuthenticationWithBiometrics`.
///    The passcode fallback matters: a user whose Face ID fails in bad light
///    should be able to complete a tip rather than be locked out of their own
///    money. Both paths still require a present human.
///
/// 2. A fresh `LAContext` per evaluation, with `touchIDAuthenticationAllowableReuseDuration`
///    left at zero. iOS would otherwise let a recent unlock satisfy a later
///    prompt without the user seeing anything — which would mean a payment
///    firing with no visible confirmation. Every tip gets its own prompt.
public struct LocalAuthenticationAuthorizer: BiometricAuthorizer {

    public init() {}

    public func evaluate(reason: String) async -> BiometricOutcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        // Explicitly no reuse: one payment, one prompt.
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(reason: error?.localizedDescription ?? "authentication unavailable")
        }

        let method = Self.describe(context.biometryType)

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: reason)
            // `evaluatePolicy` throws rather than returning false, but a
            // defensive check costs nothing and fails closed.
            return success ? .succeeded(method: method) : .failed(reason: "authentication returned false")
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .userCancelled
            case .userFallback:
                return .userFallback
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                return .unavailable(reason: laError.localizedDescription)
            default:
                return .failed(reason: laError.localizedDescription)
            }
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private static func describe(_ type: LABiometryType) -> String {
        switch type {
        case .faceID: return "faceID"
        case .touchID: return "touchID"
        case .opticID: return "opticID"
        default: return "passcode"
        }
    }
}
