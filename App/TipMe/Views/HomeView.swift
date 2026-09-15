import SwiftUI
import TipMeCore

/// The host app's main screen.
///
/// Kept intentionally small. The app exists to set up the wallet, hold the
/// funds, keep the wallet synced for the extension, and show what happened —
/// the tipping itself happens in the share sheet.
struct HomeView: View {
    let services: TipMeServices

    @State private var bitcoinBalance: Amount = .sats(0)
    @State private var usdtBalance: Amount = .usdtCents(0)
    @State private var spentToday: FiatAmount = .gbp(pence: 0)
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bitcoinBalance.formatted)
                            .font(.largeTitle.weight(.semibold))
                            .monospacedDigit()
                        if usdtBalance.isPositive {
                            Text(usdtBalance.formatted)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)

                    NavigationLink {
                        TopUpView(services: services)
                    } label: {
                        Label("Add funds", systemImage: "plus.circle.fill")
                    }
                }

                Section("Today") {
                    LabeledContent("Tipped", value: spentToday.formatted)
                    LabeledContent("Daily limit",
                                   value: FiatAmount(currencyCode: services.configuration.capPolicy.currencyCode,
                                                     minorUnits: services.configuration.capPolicy.perDay).formatted)
                }

                Section {
                    NavigationLink {
                        ActivityView(services: services)
                    } label: {
                        Label("Activity", systemImage: "list.bullet.rectangle")
                    }
                    NavigationLink {
                        SettingsView(services: services)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                Section {
                    // The one instruction most users need, since the app itself
                    // is not where tipping happens.
                    Label("Tip from TikTok or Instagram by tapping Share, then \"Tip via TipMe\".",
                          systemImage: "square.and.arrow.up")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("TipMe")
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        try? await services.backend.connect()
        try? await services.backend.sync()

        bitcoinBalance = (try? await services.backend.availableBalance(for: .bitcoin)) ?? .sats(0)
        usdtBalance = (try? await services.backend.availableBalance(for: .usdt)) ?? .usdtCents(0)
        spentToday = await services.capLedger.spentToday()
    }
}
