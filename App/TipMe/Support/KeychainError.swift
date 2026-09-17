import Foundation

/// Shared across every keychain-backed store in the app (`AccountKeychain`,
/// `CreatorTokenStore`) so error handling at call sites does not depend on
/// which store produced the failure.
enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case unexpectedData
    case status(OSStatus)

    var description: String {
        switch self {
        case .notFound: return "Not found in the keychain."
        case .unexpectedData: return "Stored keychain value is unreadable."
        case .status(let status): return "Keychain error \(status)."
        }
    }
}
