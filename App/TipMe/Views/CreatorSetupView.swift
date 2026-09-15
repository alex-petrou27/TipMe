import SwiftUI
import TipMeCore

/// Creator onboarding: link a social handle to a wallet, once.
///
/// This is the other half of the product. Senders can only tip a creator who
/// has told TipMe where their money should go, and until now the only way to do
/// that was to POST to the registry by hand.
///
/// The link is permanent until the creator changes or deletes it — senders
/// never re-establish it per payment.
struct CreatorSetupView: View {
    let services: TipMeServices

    @State private var platform: Platform = .tiktok
    @State private var username = ""
    @State private var lightningAddress = ""
    @State private var preferredAsset: Asset = .bitcoin
    @State private var minimumTipText = ""

    @State private var phase: Phase = .editing
    @State private var errorMessage: String?

    private enum Phase: Equatable {
        case editing
        case verifying
        case registering
        case done(CreatorRegistration)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.editing, .editing), (.verifying, .verifying), (.registering, .registering):
                return true
            case (.done(let a), .done(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private var parsedHandle: CreatorHandle? {
        CreatorHandle(platform: platform, rawUsername: username)
    }

    /// Handles this device has already claimed, read from the keychain so they
    /// are available offline.
    private var claimedHandles: [CreatorHandle] {
        services.creatorTokens.claimedHandles()
    }

    /// True when we hold the management token for the handle being edited, so
    /// the button can say "Update" rather than "Link" and the request can carry
    /// the token.
    private var isUpdatingOwnHandle: Bool {
        guard let handle = parsedHandle else { return false }
        return services.creatorTokens.token(for: handle) != nil
    }

    private var parsedAddress: LightningAddress? {
        LightningAddress(lightningAddress)
    }

    private var canSubmit: Bool {
        parsedHandle != nil && parsedAddress != nil && phase == .editing
    }

    var body: some View {
        Form {
            if case .done(let registration) = phase {
                completed(registration)
            } else {
                editor
            }
        }
        .navigationTitle("Get tipped")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Editing

    @ViewBuilder
    private var editor: some View {
        if !claimedHandles.isEmpty {
            Section("Linked on this device") {
                ForEach(claimedHandles, id: \.registryKey) { handle in
                    Button {
                        platform = handle.platform
                        username = handle.username
                    } label: {
                        HStack {
                            Text(handle.displayName)
                            Spacer()
                            Text(handle.platform.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Tap one to change where its tips go.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Your account") {
            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 2) {
                Text("@").foregroundStyle(.secondary)
                TextField("username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            // Validation as they type, rather than only on submit: a handle
            // that could never exist on that platform is worth saying so about
            // immediately.
            if !username.isEmpty && parsedHandle == nil {
                Text("That isn't a valid \(platform.displayName) username.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        Section("Where tips go") {
            TextField("name@wallet.com", text: $lightningAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)

            if !lightningAddress.isEmpty && parsedAddress == nil {
                Text("That doesn't look like a Lightning address.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Any Lightning address works — Alby, Strike, Wallet of Satoshi, Coinos, or your own node. Tips go straight there; TipMe never holds them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Preferences") {
            Picker("Receive in", selection: $preferredAsset) {
                Text("Bitcoin").tag(Asset.bitcoin)
                Text("USDT").tag(Asset.usdt)
            }
            .pickerStyle(.segmented)

            TextField("Minimum tip (optional)", text: $minimumTipText)
                .keyboardType(.numberPad)

            Text("Senders can pay in either asset — we convert to whichever you pick.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        Section {
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    switch phase {
                    case .verifying: Text("Checking your wallet…")
                    case .registering: Text(isUpdatingOwnHandle ? "Updating…" : "Registering…")
                    default: Text(isUpdatingOwnHandle ? "Update where tips go" : "Link my account")
                    }
                    if phase != .editing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!canSubmit)

            Text("We check your wallet can actually receive a payment before saving it. A typo here would mean every tip silently fails.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Done

    @ViewBuilder
    private func completed(_ registration: CreatorRegistration) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(registration.handle.displayName) is linked",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("Tips will go to \(registration.lightningAddress.description).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        if registration.managementToken != nil {
            Section {
                Label("Saved to this device's keychain", systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Changing where your tips go later needs a secret we've just stored for you. Keep this device, or contact support if you lose it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("One more step") {
            // Registration is open — anyone can claim any handle — so the badge
            // only means something once a human has checked the claim.
            Text("Anyone can claim a handle, so yours shows as unverified until we've checked it. Add this to your \(registration.handle.platform.displayName) bio:")
                .font(.callout)

            HStack {
                Text(registration.claimToken)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { UIPasteboard.general.string = registration.claimToken }
                    .font(.footnote)
            }

            Text(registration.verificationInstructions)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button("Link another account") {
                username = ""
                lightningAddress = ""
                errorMessage = nil
                phase = .editing
            }
        }
    }

    // MARK: - Submitting

    private func submit() async {
        guard let handle = parsedHandle, let address = parsedAddress else { return }
        errorMessage = nil
        phase = .verifying

        let minimumTip = Int64(minimumTipText.filter(\.isNumber))
            .map { Amount(asset: preferredAsset, minorUnits: $0) }

        let registrar = CreatorRegistrar(baseURL: services.configuration.registryBaseURL)

        // Verification happens inside `register`, but the phase is split so the
        // button can say which step is running — "Checking your wallet" is a
        // meaningfully different wait from "Registering".
        phase = .registering
        do {
            let registration = try await registrar.register(
                handle: handle,
                lightningAddress: address,
                preferredAsset: preferredAsset,
                minimumTip: minimumTip,
                displayName: nil,
                // Present only when this device made the original claim; the
                // registry refuses anonymous changes to an existing record.
                managementToken: services.creatorTokens.token(for: handle))

            // Issued once, on first claim. If it is not stored now, the creator
            // permanently loses the ability to move their tips elsewhere.
            if let token = registration.managementToken {
                try? services.creatorTokens.store(token: token, for: handle)
            }
            phase = .done(registration)
        } catch let error as CreatorRegistrationError {
            errorMessage = error.userFacingReason
            phase = .editing
        } catch {
            errorMessage = String(describing: error)
            phase = .editing
        }
    }
}
