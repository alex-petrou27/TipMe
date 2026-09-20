import SwiftUI
import TipMeCore

/// The four top-level destinations. Get Tipped and Settings used to live one
/// level down behind an ellipsis-menu sheet — but they are the other half of
/// this product, not secondary settings, so they get a permanent tab each,
/// the way Cash App gives Banking and Investing their own tab rather than
/// burying them in a "More" screen.
struct MainTabView: View {
    let services: TipMeServices
    let onLogout: () -> Void

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(services: services)
            }
            .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack {
                ActivityView(services: services)
            }
            .tabItem { Label("Activity", systemImage: "list.bullet") }

            NavigationStack {
                CreatorSetupView(services: services)
            }
            .tabItem { Label("Get Tipped", systemImage: "person.crop.circle.badge.checkmark") }

            NavigationStack {
                SettingsView(services: services, onLogout: onLogout)
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.brand)
    }
}

/// What the big number on Home actually shows -- see `HomeView.balancePanel`.
private enum BalanceDisplay: String, CaseIterable {
    case total, bitcoin, usdt

    var label: String {
        switch self {
        case .total: return "Total"
        case .bitcoin: return "BTC"
        case .usdt: return "USDT"
        }
    }
}

/// The main screen: balance, the four wallet actions, and a preview of
/// recent activity. Tipping-specific setup (Get Tipped) and Settings are
/// their own tabs now — see `MainTabView` — so this screen is purely the
/// wallet.
struct HomeView: View {
    let services: TipMeServices

    @State private var bitcoinBalance: Amount = .sats(0)
    @State private var usdtBalance: Amount = .usdtCents(0)
    @State private var fiatTotal: FiatAmount?
    @State private var recentActivity: [WalletTransaction] = []
    @State private var isRefreshing = false
    @State private var displayMode: BalanceDisplay = .total

    var body: some View {
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
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    /// One number by default -- what the balance is worth in the currency the
    /// person actually thinks in, hiding which asset backs it, same as
    /// before. The BTC/USDT toggle underneath is additive, not a reversal of
    /// that: it exists for the person who *wants* to see the asset a moment,
    /// the way Cash App's own Bitcoin tab lets you flip from a dollar figure
    /// to a BTC one -- it never changes what anything is held in.
    private var balancePanel: some View {
        VStack(spacing: Theme.spacingSmall) {
            Text("Your balance")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)

            Text(displayedBalance)
                .font(Theme.balance())
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, Theme.spacingSmall)
                .contentTransition(.numericText())
                .animation(Theme.motion, value: displayedBalance)

            balanceDisplayPicker
                .padding(.top, Theme.spacingSmall)
        }
        .padding(.vertical, Theme.spacingLarge)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Theme.brand.opacity(0.16), Theme.brand.opacity(0.0)],
                          startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.brand.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, Theme.spacing)
    }

    private var displayedBalance: String {
        switch displayMode {
        case .total: return fiatTotal?.formatted ?? "—"
        case .bitcoin: return bitcoinBalance.formatted
        case .usdt: return usdtBalance.formatted
        }
    }

    private var balanceDisplayPicker: some View {
        HStack(spacing: 4) {
            ForEach(BalanceDisplay.allCases, id: \.self) { mode in
                let isSelected = displayMode == mode
                Button {
                    Haptics.tap()
                    displayMode = mode
                } label: {
                    Text(mode.label)
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Theme.onBrand : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(isSelected ? Theme.brand : Color.clear, in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(4)
        .background(Theme.surfaceRaised, in: Capsule())
        .animation(Theme.motion, value: displayMode)
    }

    private var quickActions: some View {
        HStack(spacing: Theme.spacingLarge) {
            NavigationLink { SendView(services: services) } label: {
                QuickActionLabel(title: "Send", systemImage: "arrow.up")
            }
            NavigationLink { TipByHandleView(services: services) } label: {
                QuickActionLabel(title: "Tip", systemImage: "bolt.fill")
            }
            NavigationLink { DepositView(services: services) } label: {
                QuickActionLabel(title: "Deposit", systemImage: "arrow.down")
            }
            NavigationLink { WithdrawView(services: services) } label: {
                QuickActionLabel(title: "Withdraw", systemImage: "building.columns")
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
                    .foregroundStyle(Theme.brand)
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
                        if index > 0 { Divider().overlay(Theme.divider) }
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
