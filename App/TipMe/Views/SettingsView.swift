import SwiftUI
import TipMeCore

/// Settings.
///
/// The caps and the fee are shown as read-only values sourced from
/// configuration. They are not editable in-app on purpose: a send cap the user
/// can raise from inside the app during a moment of pressure is not a security
/// control, it is a suggestion.
struct SettingsView: View {
    let services: TipMeServices

    @State private var revealedMnemonic: String?
    @State private var revealError: String?
    @State private var connectedHandles: [Platform: String] = [:]
    @State private var connectingPlatform: Platform?
    @State private var accountError: String?

    private var caps: SendCapPolicy { services.configuration.capPolicy }
    private var limits: RateLimitPolicy { services.configuration.rateLimitPolicy }
    private var identityStore: SenderIdentityStore? {
        SenderIdentityStore(appGroup: services.configuration.appGroup)
    }

    var body: some View {
        Form {
            Section("Your accounts") {
                accountRow(.instagram)
                accountRow(.tiktok)
                if let accountError {
                    Text(accountError).font(.caption).foregroundStyle(.red)
                }
                Text("A \u{201C}Sending as\u{201D} badge only — sending a tip never needs this. TipMe never sees your password; connecting just proves the handle is yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fee") {
                LabeledContent("TipMe fee", value: services.configuration.feePolicy.percentageDescription)
                Text("Added on top of your tip. The creator always receives the full amount you chose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Send limits") {
                LabeledContent("Per tip", value: fiat(caps.perTip))
                LabeledContent("Per day", value: fiat(caps.perDay))
                LabeledContent("Per week", value: fiat(caps.perWeek))
                LabeledContent("Same creator",
                               value: "\(limits.sameHandleCount) per \(Int(limits.sameHandleWindow / 60)) min")
            }

            Section("Wallet") {
                if let revealedMnemonic {
                    Text(revealedMnemonic)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button("Hide") { self.revealedMnemonic = nil }
                } else {
                    Button("Show recovery phrase") { Task { await reveal() } }
                }
                if let revealError {
                    Text(revealError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Text("TipMe is non-custodial. Your keys and funds stay on this device; we never hold your balance and every tip settles directly to the creator.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { loadIdentities() }
    }

    private func accountRow(_ platform: Platform) -> some View {
        HStack {
            Text(platform.displayName)
            Spacer()
            if connectingPlatform == platform {
                ProgressView()
            } else if let username = connectedHandles[platform] {
                Text("@\(username)")
                    .foregroundStyle(.secondary)
                Button("Disconnect") { disconnect(platform) }
                    .font(.caption)
            } else {
                Button("Connect") { Task { await connect(platform) } }
                    .font(.callout)
            }
        }
    }

    private func fiat(_ minorUnits: Int64) -> String {
        FiatAmount(currencyCode: caps.currencyCode, minorUnits: minorUnits).formatted
    }

    private func loadIdentities() {
        guard let identityStore else { return }
        for platform in Platform.allCases {
            if let username = identityStore.username(for: platform) {
                connectedHandles[platform] = username
            }
        }
    }

    private func connect(_ platform: Platform) async {
        accountError = nil
        connectingPlatform = platform
        defer { connectingPlatform = nil }

        let connector = SocialAccountConnector(baseURL: services.configuration.registryBaseURL)
        do {
            let result = try await connector.connectIdentity(platform: platform)
            identityStore?.set(username: result.username, for: platform)
            connectedHandles[platform] = result.username
        } catch let error as SocialAccountConnector.ConnectorError {
            accountError = error.userFacingReason
        } catch {
            accountError = String(describing: error)
        }
    }

    private func disconnect(_ platform: Platform) {
        identityStore?.clear(platform)
        connectedHandles[platform] = nil
    }

    /// Revealing the phrase is gated behind the same biometric check a payment
    /// is — anyone holding an unlocked phone could otherwise walk off with the
    /// keys to the wallet.
    private func reveal() async {
        let outcome = await LocalAuthenticationAuthorizer()
            .evaluate(reason: "Show your recovery phrase")
        guard case .succeeded = outcome else {
            revealError = "Confirmation failed."
            return
        }
        do {
            revealedMnemonic = try WalletSetup(keychain: services.keychain).revealMnemonic()
            revealError = nil
        } catch {
            revealError = String(describing: error)
        }
    }
}
