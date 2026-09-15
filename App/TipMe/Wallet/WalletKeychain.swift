import Foundation
import Security
import TipMeCore

/// Stores the wallet mnemonic in the keychain, in a shared access group so the
/// share extension can reach it.
///
/// Protection class is `WhenUnlockedThisDeviceOnly`:
///   - *WhenUnlocked* because a share extension only ever runs while the user is
///     looking at their phone, so nothing needs the key on a locked device.
///   - *ThisDeviceOnly* because the mnemonic controls real funds and must not
///     ride an iCloud Keychain sync or an encrypted backup onto another device.
///
/// This is the app's most sensitive value by a wide margin. It is never logged,
/// never written to the App Group container, and never leaves the keychain.
public struct WalletKeychain: Sendable {

    public enum KeychainError: Error, CustomStringConvertible {
        case notFound
        case unexpectedData
        case status(OSStatus)

        public var description: String {
            switch self {
            case .notFound: return "No wallet key found. Open TipMe to finish setting up."
            case .unexpectedData: return "Stored wallet key is unreadable."
            case .status(let status): return "Keychain error \(status)."
            }
        }
    }

    private let service = "technology.tipme.wallet"
    private let account = "mnemonic"
    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup]
    }

    public func store(mnemonic: String) throws {
        guard let data = mnemonic.data(using: .utf8) else { throw KeychainError.unexpectedData }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func loadMnemonic() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data, let mnemonic = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return mnemonic
    }

    public func hasMnemonic() -> Bool {
        (try? loadMnemonic()) != nil
    }

    /// Used by "remove wallet" in settings. Irreversible without the backup
    /// phrase, which is why the UI gates it behind a typed confirmation.
    public func deleteMnemonic() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
