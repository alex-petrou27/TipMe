import SwiftUI
import TipMeCore

/// First run: create or restore a wallet.
///
/// The self-custody trade-off is stated plainly rather than buried in a
/// checkbox. A user who loses the phrase loses the funds, and TipMe genuinely
/// cannot help them — saying so up front is the only honest option.
struct OnboardingView: View {
    let services: TipMeServices
    let onComplete: () async -> Void

    @State private var mode: Mode = .intro
    @State private var mnemonic: String = ""
    @State private var restoreInput: String = ""
    @State private var confirmedBackup = false
    @State private var errorMessage: String?

    private enum Mode { case intro, created, restore }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .intro: intro
                case .created: created
                case .restore: restore
                }
            }
            .padding(24)
            .navigationTitle("TipMe")
        }
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.yellow)
            Text("Tip creators from the share sheet")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Your wallet lives on this device. TipMe never holds your money and can't freeze or recover it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()

            Button("Create a wallet") { createWallet() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("I already have a recovery phrase") { mode = .restore }
                .font(.footnote)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var created: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write this down")
                .font(.title2.weight(.semibold))
            Text("These 12 words are the only way to recover your money. Nobody at TipMe has a copy — if you lose them, the funds are gone.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(mnemonic.split(separator: " ").enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(String(word))
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Toggle("I've written these down somewhere safe", isOn: $confirmedBackup)
                .font(.footnote)

            Spacer()

            Button("Continue") {
                // The phrase is deliberately dropped from memory here; it lives
                // only in the keychain from this point on.
                mnemonic = ""
                Task { await onComplete() }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(!confirmedBackup)
        }
    }

    private var restore: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enter your recovery phrase")
                .font(.title2.weight(.semibold))
            TextEditor(text: $restoreInput)
                .frame(height: 120)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            Button("Restore") { restoreWallet() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("Back") { mode = .intro; errorMessage = nil }
                .font(.footnote)

            Spacer()
        }
    }

    private func createWallet() {
        do {
            mnemonic = try WalletSetup(keychain: services.keychain).createWallet()
            errorMessage = nil
            mode = .created
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func restoreWallet() {
        do {
            try WalletSetup(keychain: services.keychain).restoreWallet(mnemonic: restoreInput)
            restoreInput = ""
            Task { await onComplete() }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
