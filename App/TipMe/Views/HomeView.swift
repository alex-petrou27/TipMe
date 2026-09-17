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

    @State private var displayedAsset: Asset = .bitcoin
    @State private var bitcoinBalance: Amount = .sats(0)
    @State private var usdtBalance: Amount = .usdtCents(0)
    @State private var recentActivity: [WalletTransaction] = []
    @State private var isRefreshing = false
    @State private var showingMore = false

    private var currentBalance: Amount {
        displayedAsset == .bitcoin ? bitcoinBalance : usdtBalance
    }

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

    private var balancePanel: some View {
        VStack(spacing: Theme.spacingSmall) {
            AssetSwitcher(selection: $displayedAsset)

            Text(currentBalance.formatted)
                .font(Theme.balance())
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, Theme.spacingSmall)

            if displayedAsset == .bitcoin, usdtBalance.isPositive {
                Text("+ \(usdtBalance.formatted)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.spacing)
    }

    private var quickActions: some View {
        HStack(spacing: Theme.spacingLarge) {
            NavigationLink { SendView(services: services) } label: {
                QuickActionLabel(title: "Send", systemImage: "arrow.up")
            }
            NavigationLink { ReceiveView(services: services) } label: {
                QuickActionLabel(title: "Receive", systemImage: "arrow.down")
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
                Text("Nothing yet. Receive some funds or tip a creator to get started.")
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
            List {
                Section("Tipping") {
                    NavigationLink("How to tip") { HowToTipView() }
                    NavigationLink("Get tipped") { CreatorSetupView(services: services) }
                }
                Section {
                    NavigationLink("Settings") { SettingsView(services: services, onLogout: onLogout) }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
