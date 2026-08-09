import Foundation
import Security

// Scores passwords and generates high-entropy secrets so recovery bundles are resilient to offline guessing.
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

    // Generates a random password long enough to default users into the strong bucket.
    static func generate(length: Int = 24) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()-_=+[]{}")
        var bytes = [UInt8](repeating: 0, count: max(length, 1))
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { characters[Int($0) % characters.count] })
    }
}
