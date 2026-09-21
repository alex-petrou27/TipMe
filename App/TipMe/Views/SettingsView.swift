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

    @State private var isLoggingOut = false

    private var signedInEmail: String? {
        try? services.accountKeychain.loadSession().email
    }

    private var caps: SendCapPolicy { services.configuration.capPolicy }
    private var limits: RateLimitPolicy { services.configuration.rateLimitPolicy }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLarge) {
                profileHeader
                accountsSection
                helpSection
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

    /// Read-only apart from disconnecting: connecting an account happens on
    /// Get Tipped, and a platform only shows up here once it's connected.
    private var accountsSection: some View {
        sectionCard(title: "Connected accounts") {
            ConnectedAccountsList(services: services)
        }
    }

    private var helpSection: some View {
        sectionCard(title: "Help") {
            NavigationLink {
                ShareSheetGuideScreen()
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemImage: "square.and.arrow.up")
                    Text("How to add TipMe to your Share Sheet")
                        .font(Theme.body)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.pressable)
        }
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

    // MARK: - Actions

    private func fiat(_ minorUnits: Int64) -> String {
        FiatAmount(currencyCode: caps.currencyCode, minorUnits: minorUnits).formatted
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
