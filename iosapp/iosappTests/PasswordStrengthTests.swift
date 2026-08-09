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

    // Confirms generator output is non-empty and typically classified as strong.
    @Test func generatedPasswordIsStrong() {
        let generated = PasswordStrength.generate()
        #expect(!generated.isEmpty)
        #expect(PasswordStrength.score(generated).level == .strong)
    }
}
