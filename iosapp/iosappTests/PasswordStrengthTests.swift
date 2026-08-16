import Testing
@testable import iosapp

// Verifies password guidance remains stable so recovery-key UX nudges users toward strong secrets.
struct PasswordStrengthTests {
    // Confirms short single-class passwords stay in the weak bucket.
    @Test func shortPasswordIsWeak() {
        let score = PasswordStrength.score("short")
        #expect(score.level == .weak)
    }

    // Confirms mixed long passwords reach the strong bucket for generated defaults.
    @Test func longMixedPasswordIsStrong() {
        let score = PasswordStrength.score("S7f!9xQ2m#1Lb@8nR5t$0wZk")
        #expect(score.level == .strong)
    }

    // Keeps the empty-field strength copy neutral so an untouched form
    // does not look like a validation error.
    @Test func emptyPasswordUsesNeutralStrengthLabel() {
        let label = PasswordEntryView.strengthLabel(for: "")
        #expect(label == "Enter a password")
        #expect(label != "Weak")
    }

    // Confirms typed passwords surface the same buckets as PasswordStrength.
    @Test func strengthLabelMatchesPasswordStrengthBuckets() {
        #expect(PasswordEntryView.strengthLabel(for: "short") == "Weak")
        #expect(PasswordEntryView.strengthLabel(for: "S7f!9xQ2m#1Lb@8nR5t$0wZk") == "Strong")
    }

    // Confirms the segment bar stays empty until the user types, then
    // fills all three segments for a strong password.
    @Test func strengthFillCountMatchesEmptyAndStrongStates() {
        #expect(PasswordEntryView.strengthFillCount(for: "") == 0)
        #expect(PasswordEntryView.strengthFillCount(for: "S7f!9xQ2m#1Lb@8nR5t$0wZk") == 3)
    }
}
