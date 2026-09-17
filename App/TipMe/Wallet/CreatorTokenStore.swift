import Foundation
import Security
import TipMeCore

/// Keychain storage for the per-handle management token.
///
/// The token is issued exactly once, when a handle is first claimed, and is the
/// only way to change where that handle's tips go afterwards. Showing it once
/// and hoping the creator writes it down would mean most of them silently lose
/// the ability to ever move wallets.
///
/// Stored alongside the wallet key and with the same protection class: it is a
/// secret that controls a payment destination, so it must not ride an iCloud
/// Keychain sync onto another device.
public struct CreatorTokenStore: Sendable {
    private let service = "technology.tipme.creator-management"
    private let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    private func query(for handle: CreatorHandle) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: handle.registryKey,
         kSecAttrAccessGroup as String: accessGroup]
    }

    public func store(token: String, for handle: CreatorHandle) throws {
        guard let data = token.data(using: .utf8) else {
            throw KeychainError.unexpectedData
        }
        var attributes = query(for: handle)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        SecItemDelete(query(for: handle) as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func token(for handle: CreatorHandle) -> String? {
        var lookup = query(for: handle)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Every handle this device has claimed, so the app can show them without
    /// asking the registry (and without needing to be online).
    public func claimedHandles() -> [CreatorHandle] {
        var lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        lookup[kSecReturnData as String] = false

        var items: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let account = entry[kSecAttrAccount as String] as? String else { return nil }
            let parts = account.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let platform = Platform(rawValue: String(parts[0]))
            else { return nil }
            return CreatorHandle(platform: platform, rawUsername: String(parts[1]))
        }
    }

    public func delete(for handle: CreatorHandle) {
        SecItemDelete(query(for: handle) as CFDictionary)
    }
}
