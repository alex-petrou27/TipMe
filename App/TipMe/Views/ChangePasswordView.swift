import SwiftUI
import TipMeCore

/// Changes the signed-in account's password. Reachable from Settings, not
/// onboarding — this is "I know my password and want a different one," the
/// opposite situation from `OnboardingView`'s forgot-password flow.
struct ChangePasswordView: View {
    let services: TipMeServices
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didSucceed = false

    private var canSubmit: Bool {
        !currentPassword.isEmpty && newPassword.count >= 8 && newPassword == confirmPassword
    }

    var body: some View {
        Form {
            Section {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
            }

            Section {
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmPassword)
                    .textContentType(.newPassword)

                if !confirmPassword.isEmpty && newPassword != confirmPassword {
                    Text("Passwords don't match.").font(.caption).foregroundStyle(Theme.negative)
                }
            } footer: {
                Text("At least 8 characters. Every other device you're signed in on will be logged out.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).font(.caption).foregroundStyle(Theme.negative)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Text("Change password")
                        if isSubmitting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Password changed", isPresented: $didSucceed) {
            Button("OK") { dismiss() }
        } message: {
            Text("Your password has been updated.")
        }
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        guard let token = try? services.accountKeychain.loadSession().sessionToken else {
            errorMessage = "Your session expired. Log out and back in, then try again."
            return
        }

        do {
            try await services.accountClient.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword,
                sessionToken: token)
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            didSucceed = true
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        guard let accountError = error as? AccountClient.AccountError else {
            return "Something went wrong. Check your connection and try again."
        }
        switch accountError {
        case .invalidRequest:
            return "Your new password must be at least 8 characters."
        case .invalidCredentials:
            return "That's not your current password."
        case .tooManyAttempts:
            return "Too many attempts. Try again in a little while."
        case .sessionExpired:
            return "Your session expired. Log out and back in, then try again."
        case .offline:
            return "You're offline. Check your connection and try again."
        case .emailTaken, .transport, .responseMalformed, .insufficientFunds, .requestRejected:
            return "Couldn't reach TipMe. Try again."
        }
    }
}
