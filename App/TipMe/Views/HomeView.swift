import SwiftUI
import TipMeCore

/// The host app's main screen: balance, the four wallet actions, and recent
/// activity — the same shape as any mainstream Lightning wallet. Tipping-
/// specific features (paste-to-tip, creator setup, how-to) live one level
/// down, reachable from the toolbar, so the primary screen reads as a wallet
/// first and a tipping app second — which is what turning TipMe into a
/// general-purpose send/receive/withdraw app actually means.
struct HomeView: View {
    let services: TipMeServices
    let onLogout: () -> Void

    @State private var bitcoinBalance: Amount = .sats(0)
    @State private var usdtBalance: Amount = .usdtCents(0)
    @State private var fiatTotal: FiatAmount?
    @State private var recentActivity: [WalletTransaction] = []
    @State private var isRefreshing = false
    @State private var showingMore = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacingLarge) {
                    balancePanel
                    quickActions
                    PasteTipCard(services: services)
                        .padding(.horizontal, Theme.spacing)
                    activitySection
                }
                .padding(.top, Theme.spacing)
                .padding(.bottom, Theme.spacingLarge)
            }
            .background(Theme.background)
            .navigationTitle("TipMe")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingMore = true } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingMore) {
                MoreMenuView(services: services, onLogout: onLogout)
            }
            .refreshable { await refresh() }
            .task { await refresh() }
        }
        .tint(Theme.accent)
    }

    /// One number: what the balance is worth, in the currency the person
    /// actually thinks in. Nothing here says "bitcoin" or "USDT" -- which
    /// asset is actually backing it is exactly the kind of payment
    /// infrastructure this product exists to hide.
    private var balancePanel: some View {
        VStack(spacing: Theme.spacingSmall) {
            Text("Your balance")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)

            Text(fiatTotal?.formatted ?? "—")
                .font(Theme.balance())
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, Theme.spacingSmall)
                .contentTransition(.numericText())
                .animation(Theme.motion, value: fiatTotal)
        }
        .padding(.horizontal, Theme.spacing)
    }

    private var quickActions: some View {
        HStack(spacing: Theme.spacingLarge) {
            NavigationLink { SendView(services: services) } label: {
                QuickActionLabel(title: "Send", systemImage: "arrow.up")
            }
            NavigationLink { DepositView(services: services) } label: {
                QuickActionLabel(title: "Deposit", systemImage: "arrow.down")
            }
            NavigationLink { WithdrawView(services: services) } label: {
                QuickActionLabel(title: "Withdraw", systemImage: "building.columns")
            }
            NavigationLink { ActivityView(services: services) } label: {
                QuickActionLabel(title: "Activity", systemImage: "list.bullet")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            HStack {
                Text("Recent activity").font(Theme.headline)
                Spacer()
                NavigationLink("See all") { ActivityView(services: services) }
                    .font(Theme.caption)
            }
            .padding(.horizontal, Theme.spacing)

            if recentActivity.isEmpty {
                Text("Nothing yet. Deposit some funds or tip a creator to get started.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(Theme.spacing)
            } else {
                Card {
                    ForEach(Array(recentActivity.prefix(5).enumerated()), id: \.element.id) { index, tx in
                        if index > 0 { Divider() }
                        ActivityRow(transaction: tx)
                    }
                }
                .padding(.horizontal, Theme.spacing)
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        bitcoinBalance = (try? await services.backend.availableBalance(for: .bitcoin)) ?? .sats(0)
        usdtBalance = (try? await services.backend.availableBalance(for: .usdt)) ?? .usdtCents(0)
        recentActivity = (try? await services.backend.transactionHistory(limit: 5)) ?? []

        // Best-effort per asset: a rate outage on one shouldn't blank the
        // whole figure when the other is available. Both missing shows "—"
        // rather than a guessed total.
        let currency = services.configuration.fiatCurrency
        var total: FiatAmount?
        if let rate = try? await services.backend.rate(for: .bitcoin, in: currency) {
            total = rate.fiatValue(of: bitcoinBalance)
        }
        if let rate = try? await services.backend.rate(for: .usdt, in: currency) {
            let usdtFiat = rate.fiatValue(of: usdtBalance)
            total = total.map { $0 + usdtFiat } ?? usdtFiat
        }
        fiatTotal = total
    }
}

/// Everything that isn't core wallet activity: the tipping-specific setup
/// screens, spending limits, and account settings.
struct MoreMenuView: View {
    let services: TipMeServices
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacingLarge) {
                    menuGroup {
                        menuRow(icon: "questionmark.circle.fill", title: "How to tip") { HowToTipView() }
                        Divider().overlay(Theme.divider)
                        menuRow(icon: "person.crop.circle.badge.checkmark", title: "Get tipped") { CreatorSetupView(services: services) }
                        Divider().overlay(Theme.divider)
                        menuRow(icon: "at", title: "Tip by handle") { TipByHandleView(services: services) }
                    }
                    menuGroup {
                        menuRow(icon: "gearshape.fill", title: "Settings") { SettingsView(services: services, onLogout: onLogout) }
                    }
                }
                .padding(.vertical, Theme.spacing)
            }
            .background(Theme.background)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func menuGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Card { content() }
            .padding(.horizontal, Theme.spacing)
    }

    private func menuRow<Destination: View>(icon: String, title: String,
                                            @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                IconBadge(systemImage: icon)
                Text(title)
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
