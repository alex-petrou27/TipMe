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
    @State private var errorMessage: String?

    /// Indices (0-based) of the words the user must pick back out, and their
    /// answers so far.
    @State private var challengeIndices: [Int] = []
    @State private var challengeAnswers: [Int: String] = [:]
    @State private var challengeFailed = false

    private enum Mode { case intro, created, verify, shareSetup, restore }

    private var words: [String] { mnemonic.split(separator: " ").map(String.init) }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .intro: intro
                case .created: created
                case .verify: verify
                case .shareSetup: shareSetup
                case .restore: restore
                }
            }
            .padding(24)
            .navigationTitle("TipMe")
            .tint(Theme.accent)
        }
    }

    private var intro: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.textPrimary)
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
                Text(errorMessage).font(.caption).foregroundStyle(Theme.negative)
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
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    wordRow(index: index, word: word)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Spacer()

            Button("I've written them down") { beginVerification() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    /// Checks the user actually recorded the phrase, rather than tapping past a
    /// checkbox.
    ///
    /// This is the one irreversible moment in the app. A user who taps "I've
    /// written them down" without doing so has created a wallet whose funds
    /// nobody — including us — can ever recover, and they will not discover it
    /// until they need it. Asking for three specific words costs a few seconds
    /// and is the standard every serious wallet applies.
    private var verify: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Check your backup")
                .font(.title2.weight(.semibold))
            Text("Tap the right word for each position.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(challengeIndices, id: \.self) { index in
                challengeRow(for: index)
            }

            if challengeFailed {
                Label("That's not right. Check your written copy and try again.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }

            Spacer()

            Button("Confirm") { completeVerification() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(challengeAnswers.count < challengeIndices.count)

            Button("Show me the words again") {
                challengeAnswers = [:]
                challengeFailed = false
                mode = .created
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
        }
    }

    private func wordRow(index: Int, word: String) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(word)
                .font(.callout.weight(.medium))
            Spacer()
        }
    }

    private func challengeRow(for index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Word \(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(options(for: index), id: \.self) { option in
                    Button {
                        challengeAnswers[index] = option
                        challengeFailed = false
                    } label: {
                        Text(option)
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(challengeAnswers[index] == option ? Theme.accent : .secondary)
                }
            }
        }
    }

    /// Three choices per position: the real word plus two decoys drawn from the
    /// same phrase, so a user who wrote the words down but in the wrong order
    /// is also caught.
    private func options(for index: Int) -> [String] {
        guard words.indices.contains(index) else { return [] }
        let correct = words[index]
        let decoys = words.filter { $0 != correct }.shuffled().prefix(2)
        // Seeded by the index so the row does not reshuffle on every redraw.
        return ([correct] + decoys).sorted()
    }

    private func beginVerification() {
        guard words.count == 12 else { return }
        // Three positions spread across the phrase.
        challengeIndices = Array(words.indices).shuffled().prefix(3).sorted()
        challengeAnswers = [:]
        challengeFailed = false
        mode = .verify
    }

    private func completeVerification() {
        let allCorrect = challengeIndices.allSatisfy { index in
            challengeAnswers[index] == words[index]
        }
        guard allCorrect else {
            challengeFailed = true
            challengeAnswers = [:]
            return
        }
        // Drop the phrase from memory; from here it lives only in the keychain.
        mnemonic = ""
        mode = .shareSetup
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
                Text(errorMessage).font(.caption).foregroundStyle(Theme.negative)
            }

            Button("Restore") { restoreWallet() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("Back") { mode = .intro; errorMessage = nil }
                .font(.footnote)

            Spacer()
        }
    }

    /// Prompts the user to enable TipMe in the share sheet, right after their
    /// wallet exists and before they land on Home — the same cadence apps use
    /// for a notifications-permission prompt.
    ///
    /// There is no real equivalent to that prompt here. Notifications, camera,
    /// location all have a genuine system permission API a third-party app can
    /// trigger (`UNUserNotificationCenter.requestAuthorization`, and so on).
    /// Whether TipMe is favourited in the share sheet is not a permission at
    /// all — Apple exposes no API, no deep link, and no Settings.app entry for
    /// it; it is edited only from inside the share sheet's own "More → Edit"
    /// screen, which an app cannot open or complete on the user's behalf.
    ///
    /// So this does the closest real thing: it presents the *actual* system
    /// share sheet via `ShareLink`, at the one moment we can walk someone
    /// through what to do inside it. We cannot detect whether they actually
    /// toggled TipMe on afterwards — there is no API for that either — so the
    /// copy says what to do rather than confirming that it happened.
    private var shareSetup: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.and.arrow.up.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.primary)

            Text("Add TipMe to your share sheet")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("This is a one-time setup so TipMe shows up right away next time, instead of behind “More”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                shareSetupStep(1, "Tap the button below to open the real share sheet.")
                shareSetupStep(2, "Scroll the icon row to the end and tap **More**.")
                shareSetupStep(3, "Turn on **TipMe**, then drag it to the top.")
            }
            .padding(18)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            // The genuine system share sheet — not a lookalike. What the user
            // shares here doesn't matter; this exists to put them inside the
            // real "More → Edit" screen where the actual toggle lives.
            ShareLink(item: "I just set up TipMe to tip creators straight from my share sheet ⚡️") {
                Label("Open the share sheet", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button("Continue to TipMe") { Task { await onComplete() } }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("I'll do this later") { Task { await onComplete() } }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func shareSetupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 20, height: 20)
                .background(.primary, in: Circle())
            Text(.init(text))
                .font(.callout)
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
            mode = .shareSetup
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
