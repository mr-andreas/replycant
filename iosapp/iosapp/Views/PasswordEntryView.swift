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
                .pairingFieldBackground()

            if mode == .create {
                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(nil)
                    .pairingFieldBackground()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(segmentFill(at: index))
                            .frame(height: 6)
                    }
                }

                HStack {
                    Text("Strength:")
                    Text(Self.strengthLabel(for: password))
                        .fontWeight(password.isEmpty ? .regular : .semibold)
                        .foregroundStyle(password.isEmpty ? Color.secondary : color(for: score.level))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    // Keeps the empty-field strength copy neutral so an untouched form
    // does not look like a validation error.
    static func strengthLabel(for password: String) -> String {
        guard !password.isEmpty else {
            return "Enter a password"
        }
        return PasswordStrength.score(password).level.rawValue.capitalized
    }

    // Maps strength to filled bar segments so the indicator stays reserved
    // and the form does not jump on the first keystroke.
    static func strengthFillCount(for password: String) -> Int {
        guard !password.isEmpty else {
            return 0
        }
        switch PasswordStrength.score(password).level {
        case .weak:
            return 1
        case .fair:
            return 2
        case .strong:
            return 3
        }
    }

    // Fills only the segments that match the current score so unused
    // capsules stay muted until the password improves.
    private func segmentFill(at index: Int) -> Color {
        let fillCount = Self.strengthFillCount(for: password)
        guard index < fillCount else {
            return Color.gray.opacity(0.2)
        }
        return color(for: score.level)
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
