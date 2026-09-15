import Foundation

/// Runtime configuration, read from the build's Info.plist (which
/// `Config/Secrets.xcconfig` populates from `.env`).
///
/// Nothing here is hardcoded at a call site. The fee rate, the caps and the
/// rate limits are all values an operator can change without touching the
/// payment path.
public struct AppConfiguration: Sendable {
    public var breezApiKey: String
    public var breezNetwork: String
    public var registryBaseURL: URL
    public var registryPublicKey: Data
    public var feeDestination: LightningAddress
    public var feePolicy: FeePolicy
    public var capPolicy: SendCapPolicy
    public var rateLimitPolicy: RateLimitPolicy
    public var appGroup: String
    public var keychainAccessGroup: String
    public var fiatCurrency: String

    public enum ConfigurationError: Error, CustomStringConvertible {
        case missing(String)
        case malformed(String, String)

        public var description: String {
            switch self {
            case .missing(let key):
                return "Missing configuration value '\(key)'. Copy .env.example to .env and fill it in — see README."
            case .malformed(let key, let detail):
                return "Configuration value '\(key)' is invalid: \(detail)"
            }
        }
    }

    /// Fails loudly at launch rather than degrading. A wallet app that boots
    /// with a missing fee destination or an absent registry key is a wallet app
    /// that will misroute money later.
    public static func load(from bundle: [String: Any]) throws -> AppConfiguration {
        func string(_ key: String) throws -> String {
            guard let value = bundle[key] as? String, !value.isEmpty else {
                throw ConfigurationError.missing(key)
            }
            return value
        }
        func int(_ key: String, default defaultValue: Int64) -> Int64 {
            if let value = bundle[key] as? Int64 { return value }
            if let value = bundle[key] as? Int { return Int64(value) }
            if let value = bundle[key] as? String, let parsed = Int64(value) { return parsed }
            return defaultValue
        }

        guard let registryURL = URL(string: try string("TIPME_REGISTRY_BASE_URL")) else {
            throw ConfigurationError.malformed("TIPME_REGISTRY_BASE_URL", "not a URL")
        }
        guard let publicKey = Data(base64Encoded: try string("TIPME_REGISTRY_PUBLIC_KEY")),
              publicKey.count == 32 else {
            throw ConfigurationError.malformed("TIPME_REGISTRY_PUBLIC_KEY", "expected 32 base64-encoded bytes")
        }
        guard let feeAddress = LightningAddress(try string("TIPME_FEE_LIGHTNING_ADDRESS")) else {
            throw ConfigurationError.malformed("TIPME_FEE_LIGHTNING_ADDRESS", "not a lightning address")
        }

        let basisPoints = Int(int("TIPME_FEE_BASIS_POINTS", default: 300))
        guard (0...10_000).contains(basisPoints) else {
            throw ConfigurationError.malformed("TIPME_FEE_BASIS_POINTS", "must be 0-10000")
        }

        return AppConfiguration(
            breezApiKey: try string("BREEZ_API_KEY"),
            breezNetwork: (try? string("BREEZ_NETWORK")) ?? "testnet",
            registryBaseURL: registryURL,
            registryPublicKey: publicKey,
            feeDestination: feeAddress,
            feePolicy: FeePolicy(rateBasisPoints: basisPoints,
                                 bitcoin: FeePolicy.standard.bitcoin,
                                 usdt: FeePolicy.standard.usdt),
            capPolicy: SendCapPolicy(
                perTip: int("TIPME_CAP_PER_TIP_GBP_PENCE", default: 2_000),
                perDay: int("TIPME_CAP_PER_DAY_GBP_PENCE", default: 10_000),
                perWeek: int("TIPME_CAP_PER_WEEK_GBP_PENCE", default: 30_000)),
            rateLimitPolicy: RateLimitPolicy(
                sameHandleCount: Int(int("TIPME_RATELIMIT_SAME_HANDLE_COUNT", default: 3)),
                sameHandleWindow: TimeInterval(int("TIPME_RATELIMIT_SAME_HANDLE_WINDOW_S", default: 600)),
                globalCount: Int(int("TIPME_RATELIMIT_GLOBAL_COUNT", default: 20)),
                globalWindow: TimeInterval(int("TIPME_RATELIMIT_GLOBAL_WINDOW_S", default: 3600))),
            appGroup: try string("TIPME_APP_GROUP"),
            keychainAccessGroup: try string("TIPME_KEYCHAIN_ACCESS_GROUP"),
            fiatCurrency: (try? string("TIPME_FIAT_CURRENCY")) ?? "GBP")
    }
}
