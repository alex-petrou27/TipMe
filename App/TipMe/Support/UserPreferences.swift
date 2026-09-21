import Foundation
import TipMeCore

/// Per-device settings and history the user builds up, kept in the shared App
/// Group so the share extension sees the same ones.
extension TipMeServices {
    private var sharedStore: AppGroupKeyValueStore? { AppGroupKeyValueStore(appGroup: configuration.appGroup) }

    private var recentTips: RecentTipStore? {
        guard let store = sharedStore, let session = try? accountKeychain.loadSession() else { return nil }
        return RecentTipStore(store: store, userID: session.userID)
    }

    /// Returns false, saving nothing, if the set isn't consistent.
    func saveSendLimits(_ limits: SendLimitsPreference.Limits) -> Bool {
        guard let store = sharedStore else { return false }
        return SendLimitsPreference(store: store).save(limits)
    }

    func recentlyTipped() -> [CreatorHandle] {
        recentTips?.all().map(\.handle) ?? []
    }

    func recordTip(to handle: CreatorHandle) {
        recentTips?.record(handle)
    }

    func forgetRecentTip(_ handle: CreatorHandle) {
        recentTips?.remove(handle)
    }
}
