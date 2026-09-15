import SwiftUI
import TipMeCore

/// Reads the audit log back.
///
/// The same JSON-lines file the payment path writes, rendered for a human.
/// Having one source rather than a separate "history" store means the screen
/// cannot disagree with the record — if a payment is not in the log, it did not
/// happen through this app.
struct ActivityView: View {
    let services: TipMeServices

    @State private var events: [AuditEvent] = []
    @State private var exportURL: URL?

    private var settled: [AuditEvent] {
        events.filter { $0.stage == .settled }.reversed()
    }

    private var rejected: [AuditEvent] {
        events.filter { $0.outcome == .rejected }.reversed()
    }

    var body: some View {
        List {
            if settled.isEmpty && rejected.isEmpty {
                ContentUnavailableView("No tips yet",
                                       systemImage: "bolt.slash",
                                       description: Text("Share a TikTok or Instagram post and tap \"Tip via TipMe\"."))
            }

            if !settled.isEmpty {
                Section("Sent") {
                    ForEach(settled, id: \.intentID) { event in
                        row(event)
                    }
                }
            }

            if !rejected.isEmpty {
                Section("Blocked or cancelled") {
                    ForEach(Array(rejected.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.handle.map { "@\($0)" } ?? "Unknown creator")
                                .font(.callout)
                            Text(event.detail ?? event.stage.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Export audit log") { export() }
                Text("A JSON-lines record of every payment attempt and its outcome, including the ones that were refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Activity")
        .task { await reload() }
        .sheet(item: $exportURL) { url in
            ShareLink(item: url) { Text("Share audit log") }
        }
    }

    private func row(_ event: AuditEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.handle.map { "@\($0)" } ?? "Manual address")
                    .font(.callout.weight(.medium))
                Spacer()
                if let currency = event.fiatCurrency, let minor = event.fiatMinorUnits {
                    Text(FiatAmount(currencyCode: currency, minorUnits: minor).formatted)
                        .font(.callout.monospacedDigit())
                }
            }
            HStack {
                Text(event.platform?.capitalized ?? "")
                Text("·")
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        guard let log = services.auditLog as? JSONLinesAuditLog else { return }
        events = await log.readAll()
    }

    private func export() {
        exportURL = try? SharedContainer.auditLogURL(appGroup: services.configuration.appGroup)
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
