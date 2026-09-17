import SwiftUI
import TipMeCore

/// Generates something for someone else to pay — a Lightning invoice, an
/// on-chain Bitcoin address, or a Liquid address. This is also how a new
/// wallet gets its first funds, since a self-custodial balance starts at zero.
struct ReceiveView: View {
    let services: TipMeServices

    @State private var asset: Asset = .bitcoin
    @State private var method: ReceiveMethod = .lightning
    @State private var amountText: String = ""
    @State private var request: ReceiveRequest?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var copied = false

    private var availableMethods: [ReceiveMethod] {
        asset == .bitcoin ? [.lightning, .bitcoin] : [.liquid]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                AssetSwitcher(selection: $asset)
                    .padding(.horizontal, Theme.spacingLarge)
                    .onChange(of: asset) { request = nil }

                if availableMethods.count > 1 {
                    Picker("Method", selection: $method) {
                        ForEach(availableMethods, id: \.self) { Text(label(for: $0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, Theme.spacing)
                    .onChange(of: method) { request = nil }
                }

                if let request {
                    Card {
                        VStack(spacing: Theme.spacing) {
                            QRCodeView(content: request.destination)
                                .frame(width: 220, height: 220)
                                .padding(Theme.spacingSmall)
                                .background(.white, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall))

                            Text(request.destination)
                                .font(.footnote.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)

                            PrimaryButton(title: copied ? "Copied" : "Copy",
                                         systemImage: copied ? "checkmark" : "doc.on.doc") {
                                UIPasteboard.general.string = request.destination
                                copied = true
                            }
                        }
                    }

                    Card {
                        LabeledContent("Network fee", value: TipMeCore.Amount.sats(request.feeSat).formatted)
                        if let minimum = request.minimum {
                            LabeledContent("Minimum", value: minimum.formatted)
                        }
                        if let maximum = request.maximum {
                            LabeledContent("Maximum", value: maximum.formatted)
                        }
                    }
                } else {
                    Card {
                        Text("Request a specific amount, or leave it blank to accept any.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                        TextField("Amount (optional)", text: $amountText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let errorMessage {
                        Text(errorMessage).font(Theme.caption).foregroundStyle(Theme.negative)
                    }

                    PrimaryButton(title: "Generate", isLoading: isLoading) {
                        Task { await generate() }
                    }
                }

                Text("Funds settle straight into your own wallet on this device. TipMe never holds them.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingLarge)
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Receive")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func label(for method: ReceiveMethod) -> String {
        switch method {
        case .lightning: return "Lightning"
        case .bitcoin: return "On-chain"
        case .liquid: return "Liquid"
        }
    }

    private func generate() async {
        isLoading = true
        copied = false
        errorMessage = nil
        defer { isLoading = false }

        let amount: TipMeCore.Amount? = Int64(amountText.filter(\.isNumber))
            .map { TipMeCore.Amount(asset: asset, minorUnits: $0) }

        do {
            request = try await services.backend.receive(amount: amount, method: method)
        } catch let error as PaymentBackendError {
            errorMessage = TipFlowErrorText.describe(error)
        } catch {
            errorMessage = "Couldn't create that request. Try again."
        }
    }
}

/// `TipFlow`'s error copy is `internal` to TipMeCore and scoped to its own
/// describe(_:) overloads; this is the app-side equivalent for the one
/// PaymentBackendError case surfaced here, kept tiny on purpose rather than
/// duplicating TipFlow's whole error-message surface.
enum TipFlowErrorText {
    static func describe(_ error: PaymentBackendError) -> String {
        switch error {
        case .notConnected: return "Wallet isn't ready. Try again in a moment."
        case .network(let detail), .rejectedByNetwork(let detail): return detail
        default: return "Couldn't complete that request."
        }
    }
}
