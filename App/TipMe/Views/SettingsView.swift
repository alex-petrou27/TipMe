import SwiftUI
import TipMeCore

/// Settings.
///
/// The caps and the fee are shown as read-only values sourced from
/// configuration. They are not editable in-app on purpose: a send cap the user
/// can raise from inside the app during a moment of pressure is not a security
/// control, it is a suggestion.
///
/// Built from `Card`/`IconBadge`/`Theme` rather than a system `Form` -- a
/// default grouped list is what made this screen read as a stock iOS
/// settings page rather than part of this product.
struct SettingsView: View {
    let services: TipMeServices
    let onLogout: () -> Void

    @State private var connectedHandles: [Platform: String] = [:]
    @State private var connectingPlatform: Platform?
    @State private var accountError: String?
    @State private var isLoggingOut = false
    @State private var editingPlatform: Platform?
    @State private var editingUsername = ""

    private var signedInEmail: String? {
        try? services.accountKeychain.loadSession().email
    }

    private var caps: SendCapPolicy { services.configuration.capPolicy }
    private var limits: RateLimitPolicy { services.configuration.rateLimitPolicy }
    private var identityStore: SenderIdentityStore? {
        SenderIdentityStore(appGroup: services.configuration.appGroup)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLarge) {
                profileHeader
                accountsSection
                feeSection
                limitsSection
                profileSection
                footer
            }
            .padding(.vertical, Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadIdentities() }
        .animation(Theme.motion, value: connectedHandles)
        .animation(Theme.motion, value: connectingPlatform)
        .animation(Theme.motion, value: accountError)
    }

    // MARK: - Sections

    /// Identity, not a settings row -- Cash App's own Profile tab leads with
    /// who you are before any preference. An initial in a brand-colored
    /// circle plus your email, one card, no different from the live-preview
    /// treatment Get Tipped uses for the same idea.
    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.brand.opacity(0.14))
                    .frame(width: 56, height: 56)
                Text(String((signedInEmail ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.brand)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(signedInEmail ?? "Not signed in")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("TipMe account")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(Theme.spacing)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .padding(.horizontal, Theme.spacing)
    }

    private var accountsSection: some View {
        sectionCard(title: "Your accounts") {
            accountRow(.instagram)
            Divider().overlay(Theme.divider)
            accountRow(.tiktok)
            if let accountError {
                Text(accountError)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.negative)
                    .padding(.top, 4)
            }
            Text("A \u{201C}Sending as\u{201D} badge only — sending a tip never needs this, and typing your handle is enough. \u{201C}Verify via sign-in\u{201D} additionally proves it's really you, but only works for a Business or Creator account — Instagram allows no sign-in at all for a personal one.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        }
        .alert("Sending as", isPresented: editingAlertBinding) {
            TextField("Your \(editingPlatform?.displayName ?? "") handle", text: $editingUsername)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveTypedHandle() }
        }
    }

    private var editingAlertBinding: Binding<Bool> {
        Binding(get: { editingPlatform != nil }, set: { if !$0 { editingPlatform = nil } })
    }

    private var feeSection: some View {
        sectionCard(title: "Fee") {
            settingsRow(icon: "percent", label: "TipMe fee", value: services.configuration.feePolicy.percentageDescription)
            Text("Added on top of your tip. The creator always receives the full amount you chose.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        }
    }

    private var limitsSection: some View {
        sectionCard(title: "Send limits") {
            settingsRow(icon: "arrow.up.circle", label: "Per tip", value: fiat(caps.perTip))
            Divider().overlay(Theme.divider)
            settingsRow(icon: "calendar", label: "Per day", value: fiat(caps.perDay))
            Divider().overlay(Theme.divider)
            settingsRow(icon: "calendar.badge.clock", label: "Per week", value: fiat(caps.perWeek))
            Divider().overlay(Theme.divider)
            settingsRow(icon: "person.crop.circle.badge.clock", label: "Same creator",
                       value: "\(limits.sameHandleCount) per \(Int(limits.sameHandleWindow / 60)) min")
        }
    }

    private var profileSection: some View {
        sectionCard(title: "Account") {
            Button {
                Haptics.tap()
                logout()
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "rectangle.portrait.and.arrow.right",
                             tint: Theme.negative.opacity(0.16), foreground: Theme.negative)
                    Text("Log out")
                        .font(Theme.body.weight(.medium))
                        .foregroundStyle(Theme.negative)
                    Spacer()
                    if isLoggingOut { ProgressView() }
                }
            }
            .buttonStyle(.pressable)
            .disabled(isLoggingOut)
        }
    }

    private var footer: some View {
        Text("TipMe holds your balance for you, the same way a bank does — there's no recovery phrase to lose. Log in with this email and password on any device to get to your balance.")
            .font(Theme.caption)
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.spacingLarge)
    }

    // MARK: - Pieces

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            Text(title.uppercased())
                .font(Theme.label)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.spacing)
            Card {
                content()
            }
            .padding(.horizontal, Theme.spacing)
        }
    }

    private func settingsRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: icon)
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(Theme.body.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func accountRow(_ platform: Platform) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: platform == .instagram ? "camera.fill" : "music.note")
            Text(platform.displayName)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if connectingPlatform == platform {
                ProgressView()
            } else if let username = connectedHandles[platform] {
                Text("@\(username)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Remove") {
                    Haptics.tap()
                    disconnect(platform)
                }
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.negative)
                .buttonStyle(.pressable)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Set") {
                        Haptics.tap()
                        editingUsername = ""
                        editingPlatform = platform
                    }
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .buttonStyle(.pressable)

                    Button("Verify via sign-in") {
                        Haptics.tap()
                        Task { await connect(platform) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .buttonStyle(.pressable)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

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

    /// Self-declared, unverified -- no network call, nothing to fail. This is
    /// deliberately the primary path, not a fallback: the badge it sets never
    /// gates a payment (see `SenderIdentityStore`'s own doc), so requiring
    /// platform sign-in to type your own handle here was solving a problem
    /// this feature never had, while being permanently unusable on a
    /// personal Instagram account. "Verify via sign-in" stays available
    /// above for whoever does have a Business/Creator account and wants it.
    private func saveTypedHandle() {
        guard let platform = editingPlatform else { return }
        let username = editingUsername.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty else { return }
        identityStore?.set(username: username, for: platform)
        connectedHandles[platform] = username
        editingPlatform = nil
    }

    private func logout() {
        isLoggingOut = true
        Task {
            // Best-effort server-side revoke; clearing the local copy below
            // is what actually logs this device out, regardless of whether
            // the server call succeeds.
            if let session = try? services.accountKeychain.loadSession() {
                await services.accountClient.logout(sessionToken: session.sessionToken)
            }
            try? services.accountKeychain.clearSession()
            isLoggingOut = false
            onLogout()
        }
    }
}
