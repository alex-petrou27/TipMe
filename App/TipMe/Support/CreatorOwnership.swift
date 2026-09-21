import Foundation
import TipMeCore

/// Which TipMe account claimed each handle on this device.
///
/// Management tokens live in the device keychain, which survives logging out
/// and signing up as someone else -- so without this, a new account would list
/// (and offer to unlink) every handle the previous account claimed. A handle
/// counts as "yours" only if it was claimed while you were signed in; handles
/// with no recorded owner (claimed before this existed) are hidden, not deleted.
extension TipMeServices {
    private var ownerDefaults: UserDefaults? { UserDefaults(suiteName: configuration.appGroup) }

    private func ownerKey(_ handle: CreatorHandle) -> String { "creator-owner.\(handle.registryKey)" }

    private var currentUserID: String? { try? accountKeychain.loadSession().userID }

    /// Call right after a handle is claimed.
    func recordOwner(of handle: CreatorHandle) {
        guard let currentUserID else { return }
        ownerDefaults?.set(currentUserID, forKey: ownerKey(handle))
    }

    func forgetOwner(of handle: CreatorHandle) {
        ownerDefaults?.removeObject(forKey: ownerKey(handle))
    }

    /// The handles claimed by the account that's signed in now.
    func ownedClaimedHandles() -> [CreatorHandle] {
        guard let currentUserID else { return [] }
        return creatorTokens.claimedHandles().filter {
            ownerDefaults?.string(forKey: ownerKey($0)) == currentUserID
        }
    }

    /// The management token, only if the signed-in account is the one that claimed it.
    func ownedToken(for handle: CreatorHandle) -> String? {
        guard let currentUserID, ownerDefaults?.string(forKey: ownerKey(handle)) == currentUserID else { return nil }
        return creatorTokens.token(for: handle)
    }
}
