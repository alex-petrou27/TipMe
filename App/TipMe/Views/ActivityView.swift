import SwiftUI
import TipMeCore

/// Unified activity: everything the wallet actually settled, plus everything
/// the security gates refused before it could.
///
/// These are two different sources on purpose. `transactionHistory()` is the
/// backend's own record of settled payments — sends and receives, tips
/// included, since a tip settles through the same backend `send()` path as
/// any other payment. The audit log is the only place a *refused* attempt
/// exists at all: a payment blocked by a cap or a rate limit never reaches
/// the wallet, so it would otherwise leave no trace whatsoever.
///
/// One simplification worth naming: because a tip is, to the backend, just a
/// send, this feed does not relabel a settled tip back to "tip" in the
/// wallet section — doing that reliably would mean cross-referencing the
/// audit log's payment hash against wallet history, which is more machinery
/// than this pass justifies. The tip's destination and any note usually make
/// it recognisable regardless.
struct ActivityView: View {
    let services: TipMeServices

    @State private var transactions: [WalletTransaction] = []
    @State private var refused: [AuditEvent] = []
    @State private var isLoading = false
    @State private var export: ExportFile?

    private struct ExportFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacingLarge) {
                if isLoading && transactions.isEmpty && refused.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if transactions.isEmpty && refused.isEmpty {
                    emptyState
                } else {
                    if !transactions.isEmpty {
                        section("Wallet") {
                            ForEach(Array(transactions.enumerated()), id: \.element.id) { index, tx in
                                if index > 0 { Divider().overlay(Theme.divider) }
                                ActivityRow(transaction: tx)
                            }
                        }
                    }

                    if !refused.isEmpty {
                        section("Blocked or cancelled") {
                            ForEach(Array(refused.enumerated()), id: \.offset) { index, event in
                                if index > 0 { Divider().overlay(Theme.divider) }
                                refusedRow(event)
                            }
                        }
                    }
                }

                Button {
                    Haptics.tap()
                    beginExport()
                } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "square.and.arrow.up")
                        Text("Export audit log")
                            .font(Theme.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(.pressable)
                .padding(Theme.spacing)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .padding(.horizontal, Theme.spacing)
            }
            .padding(.vertical, Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Activity")
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $export) { file in
            ShareLink(item: file.url) { Text("Share audit log") }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            IconBadge(systemImage: "bolt.slash", size: 56)
            Text("No activity yet")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Send, receive, or tip a creator to see it here.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, Theme.spacingLarge)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingSmall) {
            Text(title.uppercased())
                .font(Theme.label)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.spacing)
            Card { content() }
                .padding(.horizontal, Theme.spacing)
        }
    }

    private func refusedRow(_ event: AuditEvent) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: "xmark.circle", tint: Theme.negative.opacity(0.14), foreground: Theme.negative)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.handle.map { "@\($0)" } ?? event.destination ?? "Unknown destination")
                    .font(Theme.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(event.detail ?? event.stage.rawValue)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        transactions = (try? await services.backend.transactionHistory(limit: 50)) ?? []

        if let log = services.auditLog as? JSONLinesAuditLog {
            let events = await log.readAll()
            refused = events.filter { $0.outcome == .rejected }.reversed()
        }
    }

    private func beginExport() {
        guard let url = try? SharedContainer.auditLogURL(appGroup: services.configuration.appGroup) else { return }
        export = ExportFile(url: url)
    }
}
