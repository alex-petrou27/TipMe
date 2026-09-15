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

    private var caps: SendCapPolicy { services.configuration.capPolicy }
    private var limits: RateLimitPolicy { services.configuration.rateLimitPolicy }

    var body: some View {
        Form {
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
    }

    private func fiat(_ minorUnits: Int64) -> String {
        FiatAmount(currencyCode: caps.currencyCode, minorUnits: minorUnits).formatted
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
