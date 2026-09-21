import SwiftUI
import TipMeCore

/// Change the per-tip, per-day and per-week send limits. These are what stop a
/// stolen, unlocked phone draining a balance, so saving needs Face ID (or the
/// passcode) every time -- raising a limit is the sensitive direction, but
/// lowering one is gated too so the rule is simple.
struct EditSendLimitsView: View {
    let services: TipMeServices
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var perTip: String
    @State private var perDay: String
    @State private var perWeek: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(services: TipMeServices, onSaved: @escaping () -> Void) {
        self.services = services
        self.onSaved = onSaved
        let caps = services.configuration.capPolicy
        _perTip = State(initialValue: Self.text(caps.perTip))
        _perDay = State(initialValue: Self.text(caps.perDay))
        _perWeek = State(initialValue: Self.text(caps.perWeek))
    }

    private static func text(_ minorUnits: Int64) -> String {
        minorUnits % 100 == 0 ? String(minorUnits / 100) : String(format: "%.2f", Double(minorUnits) / 100)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    Card {
                        field("Per tip", text: $perTip)
                        Divider().overlay(Theme.divider)
                        field("Per day", text: $perDay)
                        Divider().overlay(Theme.divider)
                        field("Per week", text: $perWeek)
                    }

                    Text("The most you can send in one tip, and in total over a day and a week. Changing these needs Face ID or your passcode.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.negative)
                            .multilineTextAlignment(.center)
                    }

                    PrimaryButton(title: "Save with Face ID", systemImage: "faceid", isLoading: isSaving) {
                        Task { await save() }
                    }
                }
                .padding(Theme.spacing)
            }
            .background(Theme.background)
            .navigationTitle("Send limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }
        .tint(Theme.brand)
        .presentationDetents([.medium, .large])
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Theme.body.weight(.medium).monospacedDigit())
                .frame(maxWidth: 120)
            Text(services.currencyCode)
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 2)
    }

    private func save() async {
        errorMessage = nil
        let code = services.currencyCode
        guard let tip = FiatAmount(parsing: perTip, currencyCode: code),
              let day = FiatAmount(parsing: perDay, currencyCode: code),
              let week = FiatAmount(parsing: perWeek, currencyCode: code)
        else {
            errorMessage = "Enter an amount for each limit."
            return
        }
        let limits = SendLimitsPreference.Limits(perTip: tip.minorUnits, perDay: day.minorUnits,
                                                 perWeek: week.minorUnits)
        guard limits.isConsistent else {
            errorMessage = "A tip can't be more than the daily limit, and the daily limit can't be more than the weekly one."
            return
        }

        isSaving = true
        defer { isSaving = false }
        switch await LocalAuthenticationAuthorizer().evaluate(reason: "Confirm changing your send limits") {
        case .succeeded:
            guard services.saveSendLimits(limits) else {
                errorMessage = "Couldn't save your limits. Try again."
                return
            }
            Haptics.success()
            onSaved()
            dismiss()
        case .userCancelled, .userFallback:
            break
        case .unavailable(let reason), .failed(let reason):
            errorMessage = "Couldn't confirm it's you: \(reason)"
        }
    }
}
