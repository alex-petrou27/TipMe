import SwiftUI
import TipMeCore

/// Unified activity: everything the wallet actually settled, plus everything
/// the security gates refused before it could.
///
/// These are two different sources on purpose. `transactionHistory()` is
/// Breez's own record of settled payments — sends and receives, tips
/// included, since a tip settles through the same backend `send()` path as
/// any other payment. The audit log is the only place a *refused* attempt
/// exists at all: a payment blocked by a cap or a rate limit never reaches
/// the wallet, so it would otherwise leave no trace whatsoever.
///
/// One simplification worth naming: because a tip is, to Breez, just a send,
/// this feed does not relabel a settled tip back to "tip" in the wallet
/// section — doing that reliably would mean cross-referencing the audit log's
/// payment hash against wallet history, which is more machinery than this
/// pass justifies. The tip's destination and any note usually make it
/// recognisable regardless.
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
        List {
            if isLoading && transactions.isEmpty && refused.isEmpty {
                ProgressView()
            } else if transactions.isEmpty && refused.isEmpty {
                ContentUnavailableView("No activity yet",
                                       systemImage: "bolt.slash",
                                       description: Text("Send, receive, or tip a creator to see it here."))
            }

            if !transactions.isEmpty {
                Section("Wallet") {
                    ForEach(transactions) { ActivityRow(transaction: $0) }
                }
            }

            if !refused.isEmpty {
                Section("Blocked or cancelled") {
                    ForEach(Array(refused.enumerated()), id: \.offset) { _, event in
                        refusedRow(event)
                    }
                }
            }

            Section {
                Button("Export audit log") { beginExport() }
                Text("A JSON-lines record of every payment attempt and its outcome, including the ones that were refused.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .navigationTitle("Activity")
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $export) { file in
            ShareLink(item: file.url) { Text("Share audit log") }
        }
    }

    private func refusedRow(_ event: AuditEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.handle.map { "@\($0)" } ?? event.destination ?? "Unknown destination")
                .font(Theme.body)
            Text(event.detail ?? event.stage.rawValue)
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
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
