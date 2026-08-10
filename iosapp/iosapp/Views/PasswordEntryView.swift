import SwiftUI

// Reuses recovery password entry behavior so creation and unlock screens share AutoFill-compatible fields.
struct PasswordEntryView: View {
    enum Mode {
        case create
        case recover
    }

    let mode: Mode
    @Binding var password: String
    @Binding var confirmPassword: String

    // Keeps recovery creation and unlock forms consistent while allowing either flow to hide nonessential fields.
    init(
        mode: Mode,
        password: Binding<String>,
        confirmPassword: Binding<String> = .constant("")
    ) {
        self.mode = mode
        self._password = password
        self._confirmPassword = confirmPassword
    }

    private var score: PasswordStrength.Score {
        PasswordStrength.score(password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SecureField(mode == .create ? "Password" : "Recovery password", text: $password)
                .textContentType(mode == .create ? .newPassword : .password)

            if mode == .create {
                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(nil)
            }

            HStack {
                Text("Strength:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(score.level.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: score.level))
            }
        }
    }

    // Colors strength labels so users can quickly see whether a password is safe for long-term storage.
    private func color(for level: PasswordStrength.Level) -> Color {
        switch level {
        case .weak:
            return .red
        case .fair:
            return .orange
        case .strong:
            return .green
        }
    }
}
