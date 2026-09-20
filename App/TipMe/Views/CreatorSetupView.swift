import PhotosUI
import SwiftUI
import UIKit
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
    @State private var preferredAsset: Asset = .usdt
    @State private var minimumTipText = ""

    @State private var phase: Phase = .editing
    @State private var errorMessage: String?

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingPhoto = false
    @State private var photoUploadError: String?

    @State private var isSelfVerifying = false
    @State private var selfVerifyError: String?
    @State private var showingBusinessSignIn = false

    private enum Phase: Equatable {
        case editing
        case verifying
        case registering
        case connecting
        case done(CreatorRegistration)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.editing, .editing), (.verifying, .verifying),
                 (.registering, .registering), (.connecting, .connecting):
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

    /// The address actually registered. Signed in, this is never shown or
    /// typed by the creator at all: it is never paid (tips route ledger-to-
    /// ledger once linked — see `CreatorRegistrar.register`'s own doc), so
    /// asking someone to invent a fake-looking email address before they can
    /// get tipped was pure friction with no payoff, and confusingly
    /// crypto-flavored for a product whose whole point is not needing to
    /// know this exists. Signed out, there's no account to route to yet, so
    /// a real address the creator actually controls is what a tip needs.
    private var effectiveAddress: LightningAddress? {
        guard let handle = parsedHandle else { return nil }
        if services.isSignedIn {
            return LightningAddress("\(handle.username)@tipme.internal")
        }
        return parsedAddress
    }

    private var canSubmit: Bool {
        parsedHandle != nil && effectiveAddress != nil && phase == .editing
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

        // Only shown signed out: signed in, tips route straight to the
        // account and this address is never paid, so it's never asked for
        // — see `effectiveAddress`.
        if !services.isSignedIn {
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

        // One button. It used to sit alongside an equally-weighted "Connect
        // Instagram" OAuth button above it -- two competing top-level ways to
        // do the same thing, one of which (OAuth) cannot work at all for a
        // personal account, which is what everyone testing this has. That
        // read as "none of these work" rather than "one of these works."
        // The next screen (bio code, then Verify) is the one real path;
        // OAuth is now the disclosed alternative below, for whoever actually
        // has a Business/Creator account.
        Section {
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    switch phase {
                    case .verifying: Text("Checking…")
                    case .registering: Text(isUpdatingOwnHandle ? "Updating…" : "Getting you set up…")
                    default: Text(isUpdatingOwnHandle ? "Update where tips go" : "Get tipped")
                    }
                    if phase == .verifying || phase == .registering {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!canSubmit)

            Text(services.isSignedIn
                 ? "Tips will go straight to your TipMe balance. You'll confirm it's really your account on the next screen."
                 : "We check your wallet can actually receive a payment before saving it. A typo here would mean every tip silently fails.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            DisclosureGroup("Have a Business or Creator account?", isExpanded: $showingBusinessSignIn) {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        switch phase {
                        case .connecting: Text("Connecting to \(platform.displayName)…")
                        default: Label("Sign in with \(platform.displayName) instead", systemImage: "checkmark.seal")
                        }
                        if phase == .connecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canSubmit)

                Text(platform == .instagram
                     ? "Only works for a Business or Creator account — Instagram allows no sign-in at all for a personal one. Skip this unless you know you have one; \"Get tipped\" above works for any account."
                     : "Signs you into TikTok to prove this handle is yours instantly, no bio code needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
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

        if registration.verified {
            Section {
                if registration.verifiedVia == "self" {
                    Label("Self-verified", systemImage: "checkmark.seal")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("You confirmed this yourself, since \(registration.handle.platform.displayName) offers no automated way to check a personal account's bio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Verified with \(registration.handle.platform.displayName)", systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } else if services.isSignedIn {
            Section("One more step") {
                // Registration is open — anyone can claim any handle — so the badge
                // only means something once this is confirmed. Instagram and TikTok
                // give us no automated way to check a personal account's bio (see
                // CreatorRegistrar.selfVerify), so this is a self-check the account
                // owner completes themselves rather than a platform-confirmed one.
                Text("Anyone can claim a handle, so yours shows as unverified until you confirm it. Add this to your \(registration.handle.platform.displayName) bio, then tap Verify:")
                    .font(.callout)

                HStack {
                    Text(registration.claimToken)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = registration.claimToken }
                        .font(.footnote)
                }

                Button {
                    Task { await selfVerify(registration) }
                } label: {
                    HStack {
                        Text(isSelfVerifying ? "Checking…" : "I've added it — Verify")
                        if isSelfVerifying {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSelfVerifying)

                if let selfVerifyError {
                    Text(selfVerifyError).font(.caption).foregroundStyle(.red)
                }

                Text("This confirms it's you without waiting on Instagram or TikTok, which offer no way to check a personal account's bio automatically. Shown as \"Self-verified\" rather than platform-verified — a real distinction, not the same badge Business/Creator sign-in earns.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("One more step") {
                Text("Anyone can claim a handle, so yours shows as unverified until it's checked. Add this to your \(registration.handle.platform.displayName) bio, then sign in to a TipMe account and re-link this handle to verify it yourself.")
                    .font(.callout)

                HStack {
                    Text(registration.claimToken)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { UIPasteboard.general.string = registration.claimToken }
                        .font(.footnote)
                }
            }
        }

        Section("Photo") {
            // Read into a plain, Sendable local before the closure, rather
            // than the @State bool directly inside it — PhotosPicker's label
            // closure is now @Sendable on newer SDKs, and a MainActor-isolated
            // stored property can't be read from inside one directly.
            let photoButtonTitle = isUploadingPhoto ? "Uploading…" : "Add a photo"
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label(photoButtonTitle, systemImage: "photo")
            }
            .disabled(isUploadingPhoto)

            if let photoUploadError {
                Text(photoUploadError).font(.caption).foregroundStyle(.red)
            }

            Text("Shown on the confirm screen when someone tips you. Optional, and never affects where tips go.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await uploadPhoto(newItem, for: registration.handle) }
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
        guard let handle = parsedHandle, let address = effectiveAddress else { return }
        errorMessage = nil
        phase = .verifying

        let minimumTip = Int64(minimumTipText.filter(\.isNumber))
            .map { Amount(asset: preferredAsset, minorUnits: $0) }

        let registrar = CreatorRegistrar(baseURL: services.configuration.registryBaseURL)
        let session = try? services.accountKeychain.loadSession()

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
                managementToken: services.creatorTokens.token(for: handle),
                // Signed in -> link this handle to the account, and skip the
                // live Lightning check: once linked, tips route ledger-to-
                // ledger and never touch this address at all. See
                // CreatorRegistrar.register's own doc for why that's safe.
                sessionToken: session?.sessionToken,
                skipAddressVerification: session != nil)

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

    // MARK: - Self-verifying

    private func selfVerify(_ registration: CreatorRegistration) async {
        guard let session = try? services.accountKeychain.loadSession() else {
            selfVerifyError = "Sign in to verify this handle."
            return
        }
        selfVerifyError = nil
        isSelfVerifying = true
        defer { isSelfVerifying = false }

        let registrar = CreatorRegistrar(baseURL: services.configuration.registryBaseURL)
        do {
            try await registrar.selfVerify(handle: registration.handle,
                                           claimToken: registration.claimToken,
                                           sessionToken: session.sessionToken)
            phase = .done(CreatorRegistration(
                handle: registration.handle,
                lightningAddress: registration.lightningAddress,
                verified: true,
                verifiedVia: "self",
                claimToken: registration.claimToken,
                verificationInstructions: registration.verificationInstructions,
                managementToken: registration.managementToken))
        } catch let error as CreatorRegistrationError {
            selfVerifyError = error.userFacingReason
        } catch {
            selfVerifyError = String(describing: error)
        }
    }

    // MARK: - Connecting

    /// Registers (or re-verifies) this handle by signing into the platform
    /// itself, rather than the bio-code round trip `submit()` uses. One call
    /// does what used to take two steps and a human: claim the handle, prove
    /// it is really this creator's, and mark it verified, all in the same
    /// sign-in.
    private func connect() async {
        guard let handle = parsedHandle, let address = effectiveAddress else { return }
        errorMessage = nil
        phase = .connecting

        let minimumTip = Int64(minimumTipText.filter(\.isNumber))
            .map { Amount(asset: preferredAsset, minorUnits: $0) }

        let connector = SocialAccountConnector(baseURL: services.configuration.registryBaseURL)
        do {
            let session = try await connector.connect(
                platform: handle.platform,
                username: handle.username,
                lightningAddress: address,
                preferredAsset: preferredAsset,
                minimumTip: minimumTip,
                displayName: nil)

            // Only present on a first claim; an existing record's token is
            // already in the keychain and does not need to be re-issued.
            if let token = session.managementToken {
                try? services.creatorTokens.store(token: token, for: handle)
            }
            phase = .done(CreatorRegistration(
                handle: session.handle,
                lightningAddress: session.lightningAddress,
                verified: session.verified,
                verifiedVia: session.verified ? "oauth" : nil,
                claimToken: session.claimToken ?? "",
                verificationInstructions: "",
                managementToken: session.managementToken))
        } catch let error as SocialAccountConnector.ConnectorError {
            errorMessage = error.userFacingReason
            phase = .editing
        } catch {
            errorMessage = String(describing: error)
            phase = .editing
        }
    }

    // MARK: - Photo

    /// Re-encodes whatever the photo library hands back (often HEIC) as a
    /// size-capped JPEG, so the upload always matches what the registry's
    /// `/photo` endpoint accepts rather than depending on the source format.
    private func uploadPhoto(_ item: PhotosPickerItem?, for handle: CreatorHandle) async {
        guard let item else { return }
        photoUploadError = nil
        isUploadingPhoto = true
        defer { isUploadingPhoto = false }

        guard let token = services.creatorTokens.token(for: handle) else {
            photoUploadError = "Couldn't find this device's management token for this handle."
            return
        }

        do {
            guard let rawData = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: rawData),
                  let jpegData = Self.resizedJPEG(image, maxDimension: 512, quality: 0.85)
            else {
                photoUploadError = "Couldn't read that photo."
                return
            }
            let uploader = CreatorPhotoUploader(baseURL: services.configuration.registryBaseURL)
            try await uploader.upload(handle: handle, imageData: jpegData, format: .jpeg,
                                      managementToken: token)
        } catch let error as SocialOAuthError {
            photoUploadError = error.userFacingReason
        } catch {
            photoUploadError = String(describing: error)
        }
    }

    private static func resizedJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: targetSize)) }
        return resized.jpegData(compressionQuality: quality)
    }
}
