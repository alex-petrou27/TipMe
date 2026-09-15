import Foundation
import TipMeCore

/// `KeyValueStore` backed by the shared App Group container.
///
/// This is what makes the security gates real. The host app and the share
/// extension are separate processes; if each kept its own counters, a user (or
/// anything driving the app) could reset every cap and rate limit simply by
/// switching entry point.
public final class AppGroupKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init?(appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Well-known locations inside the shared container.
public enum SharedContainer {
    public static func root(appGroup: String) throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw ContainerError.appGroupUnavailable(appGroup)
        }
        return url
    }

    /// Breez's working directory. Shared so the extension opens a wallet the
    /// host app has already synced rather than cold-syncing under a memory cap.
    public static func walletWorkingDirectory(appGroup: String) throws -> URL {
        try root(appGroup: appGroup).appendingPathComponent("wallet", isDirectory: true)
    }

    /// Audit log. One file for both processes, so the record of what the app did
    /// is complete rather than split in two.
    public static func auditLogURL(appGroup: String) throws -> URL {
        try root(appGroup: appGroup)
            .appendingPathComponent("audit", isDirectory: true)
            .appendingPathComponent("payments.jsonl")
    }

    public enum ContainerError: Error, CustomStringConvertible {
        case appGroupUnavailable(String)
        public var description: String {
            switch self {
            case .appGroupUnavailable(let group):
                return "App Group '\(group)' is not available. Check the entitlements on both targets — see README."
            }
        }
    }
}
