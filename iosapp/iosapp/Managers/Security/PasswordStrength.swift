import Foundation

// Scores passwords so recovery setup can nudge users away from weak secrets.
enum PasswordStrength {
    enum Level: String {
        case weak
        case fair
        case strong
    }

    // Summarizes a password quality estimate so UI can show guidance while users type.
    struct Score {
        let level: Level
        let entropyBits: Double
    }

    // Estimates entropy from character classes and length to give users immediate brute-force risk feedback.
    static func score(_ password: String) -> Score {
        guard !password.isEmpty else {
            return Score(level: .weak, entropyBits: 0)
        }
        var pool = 0
        if password.rangeOfCharacter(from: .lowercaseLetters) != nil { pool += 26 }
        if password.rangeOfCharacter(from: .uppercaseLetters) != nil { pool += 26 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { pool += 10 }
        if password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*()-_=+[]{};:,.?/")) != nil { pool += 24 }
        pool = max(pool, 10)
        let bits = Double(password.count) * log2(Double(pool))
        let level: Level
        if bits < 45 {
            level = .weak
        } else if bits < 70 {
            level = .fair
        } else {
            level = .strong
        }
        return Score(level: level, entropyBits: bits)
    }
}
