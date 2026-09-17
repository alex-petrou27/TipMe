import Foundation
import Security
import TipMeCore

/// Stores the signed-in account's session token (with its user id and
/// email) in the keychain, in a shared access group so the share extension
/// can authenticate too.
///
/// TipMe is custodial: this token is what stands between anyone who can
/// read it and the account's actual money, so it gets the same protection
/// class the wallet mnemonic used to have.
///
///   - *WhenUnlocked* because a share extension only ever runs while the
///     user is looking at their phone, so nothing needs the token on a
///     locked device.
///   - *ThisDeviceOnly* because the token reaches real funds and must not
///     ride an iCloud Keychain sync or an encrypted backup onto another
///     device -- a stolen backup should not be a stolen wallet.
public struct AccountKeychain: Sendable {
    public struct StoredSession: Codable, Sendable {
        public let userID: String
        public let email: String
        public let sessionToken: String

        public init(userID: String, email: String, sessionToken: String) {
            self.userID = userID
            self.email = email
            self.sessionToken = sessionToken
        }

        public init(_ session: AccountClient.Session) {
            self.init(userID: session.userID, email: session.email, sessionToken: session.sessionToken)
        }
    }

    private let service = "technology.tipme.account"
    private let account = "session"
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

    public func store(_ session: StoredSession) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(session)
        } catch {
            throw KeychainError.unexpectedData
        }

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func loadSession() throws -> StoredSession {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data else { throw KeychainError.unexpectedData }
        do {
            return try JSONDecoder().decode(StoredSession.self, from: data)
        } catch {
            throw KeychainError.unexpectedData
        }
    }

    public func hasSession() -> Bool {
        (try? loadSession()) != nil
    }

    /// Used by "log out." Clearing the local copy is what actually logs the
    /// device out; the server-side session is best-effort revoked alongside
    /// this (see `AccountClient.logout`) but is not what this depends on.
    public func clearSession() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
