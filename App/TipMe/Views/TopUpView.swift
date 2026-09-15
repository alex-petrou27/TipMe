import SwiftUI
import TipMeCore

/// Deposit screen.
///
/// Three methods because they have genuinely different trade-offs, and the fee
/// for each is shown before the user commits rather than discovered afterwards.
struct TopUpView: View {
    let services: TipMeServices

    @State private var method: WalletFunding.DepositDestination.Method = .lightning
    @State private var destination: WalletFunding.DepositDestination?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: $method) {
                    ForEach(WalletFunding.DepositDestination.Method.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: method) { destination = nil }
            }

            if let destination {
                Section("Send to") {
                    Text(destination.destination)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)

                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = destination.destination
                        copied = true
                    }
                }

                Section("Costs") {
                    LabeledContent("Network fee", value: Amount.sats(destination.feesSat).formatted)
                    if let minimum = destination.minimumSat {
                        LabeledContent("Minimum", value: Amount.sats(minimum).formatted)
                    }
                    if let maximum = destination.maximumSat {
                        LabeledContent("Maximum", value: Amount.sats(maximum).formatted)
                    }
                }
            } else {
                Section {
                    Button(isLoading ? "Getting address…" : "Get deposit address") {
                        Task { await load() }
                    }
                    .disabled(isLoading)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Text("Your funds stay on this device. TipMe can't access, freeze, or recover them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add funds")
    }

    private func load() async {
        isLoading = true
        copied = false
        defer { isLoading = false }
        do {
            destination = try await WalletFunding(backend: services.backend)
                .depositDestination(method: method, amountSat: nil)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
