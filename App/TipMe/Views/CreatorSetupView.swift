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

    @State private var platform: Platform = .instagram
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
        services.ownedClaimedHandles()
    }

    /// True when we hold the management token for the handle being edited, so
    /// the button can say "Update" rather than "Link" and the request can carry
    /// the token.
    private var isUpdatingOwnHandle: Bool {
        guard let handle = parsedHandle else { return false }
        return services.ownedToken(for: handle) != nil
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
        ScrollView {
            VStack(spacing: Theme.spacingLarge) {
                if case .done(let registration) = phase {
                    completed(registration)
                } else {
                    editor
                }
            }
            .padding(.vertical, Theme.spacing)
        }
        .background(Theme.background)
        .onAppear { ConnectedAccountsModel.shared(for: services).reload() }
        .navigationTitle("Get tipped")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { HowToTipView() } label: {
                    Image(systemName: "questionmark.circle")
                }
            }
        }
        .animation(Theme.motion, value: platform)
        .animation(Theme.motion, value: phase)
    }

    // MARK: - Editing

    @ViewBuilder
    private var editor: some View {
        previewCard(handle: previewHandleText, platform: platform, confirmed: false)

        ConnectAccountsCard(services: services)

        if !claimedHandles.isEmpty {
            Card {
                ForEach(Array(claimedHandles.enumerated()), id: \.element.registryKey) { index, handle in
                    if index > 0 { Divider().overlay(Theme.divider) }
                    Button {
                        Haptics.tap()
                        platform = handle.platform
                        username = handle.username
                    } label: {
                        HStack {
                            Text(handle.displayName).font(Theme.body.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(handle.platform.displayName)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, Theme.spacing)
        }

        Card {
            Picker("Platform", selection: $platform) {
                ForEach(Platform.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 6)

            HStack(spacing: 3) {
                Text("@")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                TextField("yourhandle", text: $username)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if !username.isEmpty && parsedHandle == nil {
                Text("Not a valid \(platform.displayName) username.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.negative)
            }

            if !lightningAddressFieldHidden {
                Divider().overlay(Theme.divider).padding(.vertical, 4)
                TextField("name@wallet.com", text: $lightningAddress)
                    .font(Theme.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                if !lightningAddress.isEmpty && parsedAddress == nil {
                    Text("Not a Lightning address.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.negative)
                }
            }
        }
        .padding(.horizontal, Theme.spacing)

        Card {
            Picker("Receive in", selection: $preferredAsset) {
                Text("Bitcoin").tag(Asset.bitcoin)
                Text("USDT").tag(Asset.usdt)
            }
            .pickerStyle(.segmented)

            TextField("Minimum tip (optional)", text: $minimumTipText)
                .font(Theme.body)
                .keyboardType(.numberPad)
                .padding(.top, 8)
        }
        .padding(.horizontal, Theme.spacing)

        if let errorMessage {
            Text(errorMessage)
                .font(Theme.caption)
                .foregroundStyle(Theme.negative)
                .padding(.horizontal, Theme.spacingLarge)
                .multilineTextAlignment(.center)
        }

        PrimaryButton(title: primaryButtonTitle,
                     isLoading: phase == .verifying || phase == .registering,
                     isDisabled: !canSubmit) {
            Task { await submit() }
        }
        .padding(.horizontal, Theme.spacing)

        DisclosureGroup("Have a Business or Creator account?", isExpanded: $showingBusinessSignIn) {
            Button {
                Task { await connect() }
            } label: {
                HStack {
                    Text(phase == .connecting ? "Connecting…" : "Sign in with \(platform.displayName)")
                    if phase == .connecting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!canSubmit)
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(Theme.brand)
            .padding(.top, 6)

            Text(platform == .instagram
                 ? "Personal accounts can't sign in at all — \"Get tipped\" above works for any account."
                 : "Verifies instantly, no code needed.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(Theme.body.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.spacingLarge)
    }

    private var lightningAddressFieldHidden: Bool { services.isSignedIn }

    private var previewHandleText: String { username.isEmpty ? "yourhandle" : username }

    private var primaryButtonTitle: String {
        switch phase {
        case .verifying: return "Checking…"
        case .registering: return isUpdatingOwnHandle ? "Updating…" : "Setting up…"
        default: return isUpdatingOwnHandle ? "Update" : "Get tipped"
        }
    }

    // MARK: - Live preview

    /// What a sender actually sees. The centerpiece of this screen on
    /// purpose: filling in a form has no payoff of its own, but watching
    /// your own tip card come together as you type does.
    private func previewCard(handle: String, platform: Platform, confirmed: Bool) -> some View {
        VStack(spacing: 10) {
            Text(confirmed ? "YOU'RE LIVE" : "WHAT SENDERS SEE")
                .font(Theme.label)
                .foregroundStyle(confirmed ? Theme.positive : Theme.textTertiary)

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Theme.brand.opacity(0.14))
                        .frame(width: 50, height: 50)
                    Text(String(handle.prefix(1)).uppercased())
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.brand)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(handle)")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    HStack(spacing: 4) {
                        Image(systemName: platform == .instagram ? "camera.fill" : "music.note")
                            .font(.system(size: 10, weight: .semibold))
                        Text(platform.displayName)
                            .font(Theme.caption)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 8)

                Text("£5")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.onBrand)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.brand, in: Capsule())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder((confirmed ? Theme.positive : Theme.brand).opacity(0.28), lineWidth: 1.5)
        )
        .padding(.horizontal, Theme.spacing)
        .animation(Theme.motion, value: handle)
    }

    // MARK: - Done

    @ViewBuilder
    private func completed(_ registration: CreatorRegistration) -> some View {
        ZStack {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(Theme.positive)
                Text("You're set up")
                    .font(Theme.balance(30))
                    .foregroundStyle(Theme.textPrimary)
                Text(services.isSignedIn ? "Tips work right now." : "Tips go to \(registration.lightningAddress.description).")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, Theme.spacing)
            ConfettiBurstView()
        }

        previewCard(handle: registration.handle.username, platform: registration.handle.platform, confirmed: true)

        if registration.verified {
            Card {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "checkmark.seal.fill", tint: Theme.positive.opacity(0.16), foreground: Theme.positive)
                    Text(registration.verifiedVia == "self" ? "Self-verified" : "Verified with \(registration.handle.platform.displayName)")
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(.horizontal, Theme.spacing)
        } else if services.isSignedIn {
            verifyDisclosure(registration)
        }

        Card {
            let photoButtonTitle = isUploadingPhoto ? "Uploading…" : "Add a photo"
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "photo")
                    Text(photoButtonTitle)
                        .font(Theme.body.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
            }
            .disabled(isUploadingPhoto)

            if let photoUploadError {
                Text(photoUploadError).font(Theme.caption).foregroundStyle(Theme.negative)
            }
        }
        .padding(.horizontal, Theme.spacing)
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task { await uploadPhoto(newItem, for: registration.handle) }
        }

        Button("Link another account") {
            Haptics.tap()
            username = ""
            lightningAddress = ""
            errorMessage = nil
            phase = .editing
        }
        .font(Theme.body.weight(.semibold))
        .foregroundStyle(Theme.brand)
        .buttonStyle(.pressable)
    }

    private func verifyDisclosure(_ registration: CreatorRegistration) -> some View {
        DisclosureGroup("Add a verified badge") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add this to your \(registration.handle.platform.displayName) bio:")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack {
                    Text(registration.claimToken)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        Haptics.tap()
                        UIPasteboard.general.string = registration.claimToken
                    }
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.brand)
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
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(Theme.brand)

                if let selfVerifyError {
                    Text(selfVerifyError).font(Theme.caption).foregroundStyle(Theme.negative)
                }
            }
            .padding(.top, 6)
        }
        .font(Theme.body.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
        .padding(Theme.spacing)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .padding(.horizontal, Theme.spacing)
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
                managementToken: services.ownedToken(for: handle),
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
                services.recordOwner(of: handle)
            }
            Haptics.success()
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
            Haptics.success()
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
                services.recordOwner(of: handle)
            }
            Haptics.success()
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

        guard let token = services.ownedToken(for: handle) else {
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
