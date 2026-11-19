import Foundation
import LibGit2
import Yams

// One key holder's mTLS key and age key, stored in the clear at
// pubkeys/{name}.yaml. gitd has to authorize devices before any of
// them has unwrapped the KEK, so the file is not a manifest. The
// display name is the exception: it is sealed so the server cannot
// read "Andreas's iPhone" or move that name onto another key.
public struct KeySet: Codable, Equatable {
    public var apiVersion: String
    public var kind: String
    public var metadata: Metadata
    public var spec: Spec

    public struct Metadata: Codable, Equatable {
        public var name: String

        public init(name: String) {
            self.name = name
        }
    }

    // DisplayName is optional. A server migration cannot seal one,
    // and readers then show metadata.name.
    public struct Spec: Codable, Equatable {
        public var type: String
        public var mtlsPublicKey: String
        public var agePublicKey: String
        public var displayName: DisplayName?

        public init(
            type: String,
            mtlsPublicKey: String,
            agePublicKey: String,
            displayName: DisplayName? = nil
        ) {
            self.type = type
            self.mtlsPublicKey = mtlsPublicKey
            self.agePublicKey = agePublicKey
            self.displayName = displayName
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case mtlsPublicKey
            case agePublicKey
            case displayName
        }

        // Omits a missing display name so a rewritten file does not
        // grow a null that other clients would have to treat as a name.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            mtlsPublicKey = try container.decode(String.self, forKey: .mtlsPublicKey)
            agePublicKey = try container.decode(String.self, forKey: .agePublicKey)
            displayName = try container.decodeIfPresent(DisplayName.self, forKey: .displayName)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(mtlsPublicKey, forKey: .mtlsPublicKey)
            try container.encode(agePublicKey, forKey: .agePublicKey)
            try container.encodeIfPresent(displayName, forKey: .displayName)
        }
    }

    public struct DisplayName: Codable, Equatable {
        public var kekEpoch: Int
        public var ciphertext: String

        public init(kekEpoch: Int, ciphertext: String) {
            self.kekEpoch = kekEpoch
            self.ciphertext = ciphertext
        }
    }

    public static let apiVersionValue = "gitdb.replycant.com/v1alpha1"
    public static let kindValue = "KeySet"
    public static let typeDevice = "device"
    public static let typeRecovery = "recovery"
    // A display label for a program that holds a key. It does not
    // change who the epoch is wrapped for.
    public static let typeApp = "app"
    // Binds a sealed name to metadata.name. A server that copies the
    // ciphertext onto another key set fails authentication.
    static let displayNameAADPrefix = "replycant-keyset-display-name-v1"
    private static let namePattern = try! NSRegularExpression(
        pattern: "^[a-z][a-z0-9-]{0,252}$"
    )

    public init(apiVersion: String, kind: String, metadata: Metadata, spec: Spec) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.metadata = metadata
        self.spec = spec
    }

    // Path is where this key set lives. The file stem must equal
    // metadata.name so a rename cannot claim another holder's identity.
    public static func path(name: String) -> String {
        "pubkeys/\(name).yaml"
    }

    public static func isValidName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return namePattern.firstMatch(in: name, range: range) != nil
    }

    // Turns a user-entered label into a metadata name. The sealed
    // display name keeps the original text; this is only the filename.
    public static func metadataName(from raw: String) -> String {
        var output = ""
        var previousDash = false
        for character in raw.lowercased() {
            let asciiLetter = character.isASCII && character.isLetter
            let asciiDigit = character.isASCII && character.isNumber
            if asciiLetter || asciiDigit {
                output.append(character)
                previousDash = false
                continue
            }
            let separator = character == " " || character == "-" || character == "_" || character == "'"
            if separator && !output.isEmpty && !previousDash {
                output.append("-")
                previousDash = true
            }
        }
        while output.last == "-" {
            output.removeLast()
        }
        if output.isEmpty || (output.first?.isNumber == true) {
            output = output.isEmpty ? "device" : "device-\(output)"
        }
        if output.count > 253 {
            output = String(output.prefix(253))
            while output.last == "-" {
                output.removeLast()
            }
        }
        return output
    }

    // Parses a key set the way gitd does, so a file this client writes
    // is a file the server will authorize.
    public static func parse(_ yaml: String) throws -> KeySet {
        let decoded: KeySet
        do {
            decoded = try YAMLDecoder().decode(KeySet.self, from: yaml)
        } catch {
            throw KeySetError.malformed("parse key set: \(error)")
        }
        try decoded.validate()
        return decoded
    }

    // Writes the file body. Refuses a key set parse would reject, so
    // callers cannot publish a file gitd will skip.
    public func yaml() throws -> String {
        try validate()
        return try YAMLEncoder().encode(self)
    }

    // Seals a label to one key set and one KEK epoch. `name` is
    // metadata.name and becomes the additional authenticated data.
    public static func encryptDisplayName(
        kek: Data,
        epoch: Int,
        name: String,
        plaintext: String
    ) throws -> DisplayName {
        guard epoch >= 1 else {
            throw KeySetError.invalidDisplayName
        }
        guard !plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeySetError.invalidDisplayName
        }
        guard isValidName(name) else {
            throw KeySetError.invalidDisplayName
        }
        let combined = try EncryptionUtils.encryptAESGCM(
            plaintext: Data(plaintext.utf8),
            key: kek,
            authenticatedData: displayNameAAD(name)
        )
        return DisplayName(
            kekEpoch: epoch,
            ciphertext: combined.base64EncodedString()
        )
    }

    // Opens a sealed label. Fails when the file has none, or when
    // metadata.name is not the name the label was sealed to.
    public func decryptDisplayName(kek: Data) throws -> String {
        guard let sealed = spec.displayName else {
            throw KeySetError.displayNameAbsent
        }
        guard sealed.kekEpoch >= 1,
              let combined = Data(base64Encoded: sealed.ciphertext) else {
            throw KeySetError.invalidDisplayName
        }
        let plain: Data
        do {
            plain = try EncryptionUtils.decryptAESGCM(
                ciphertext: combined,
                key: kek,
                authenticatedData: Self.displayNameAAD(metadata.name)
            )
        } catch {
            throw KeySetError.invalidDisplayName
        }
        guard let text = String(data: plain, encoding: .utf8) else {
            throw KeySetError.invalidDisplayName
        }
        return text
    }

    // The name Settings shows. A missing or unreadable seal falls back
    // to the slug, which is what a migrated library has until this
    // device fills its own name in.
    public func resolvedDisplayName(kek: Data?) -> String {
        guard let kek else {
            return metadata.name
        }
        return (try? decryptDisplayName(kek: kek)) ?? metadata.name
    }

    // Reads every key set gitd would authorize. Invalid files and
    // files whose metadata.name does not match the stem are skipped
    // so one bad write cannot hide the rest of the library.
    public static func readAll(in repository: Repository) throws -> [Stored] {
        let files = try repository.listFiles(in: "pubkeys")
        var stored: [Stored] = []
        for path in files where path.hasSuffix(".yaml") {
            let text = try repository.readFile(at: path)
            guard let keySet = try? parse(text) else {
                continue
            }
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard keySet.metadata.name == stem else {
                continue
            }
            stored.append(Stored(path: path, keySet: keySet))
        }
        return stored
    }

    public struct Stored: Equatable {
        public let path: String
        public let keySet: KeySet
    }

    func validate() throws {
        guard apiVersion == Self.apiVersionValue else {
            throw KeySetError.malformed("unsupported key set apiVersion \(apiVersion)")
        }
        guard kind == Self.kindValue else {
            throw KeySetError.malformed("unsupported key set kind \(kind)")
        }
        guard Self.isValidName(metadata.name) else {
            throw KeySetError.malformed("invalid key set name \(metadata.name)")
        }
        switch spec.type {
        case Self.typeDevice, Self.typeRecovery, Self.typeApp:
            break
        default:
            throw KeySetError.malformed("unsupported key set type \(spec.type)")
        }
        guard Self.hasSSHPublicKey(spec.mtlsPublicKey) else {
            throw KeySetError.malformed("mtls public key")
        }
        guard Self.hasAgePublicKey(spec.agePublicKey) else {
            throw KeySetError.malformed("age public key")
        }
        if let displayName = spec.displayName {
            guard displayName.kekEpoch >= 1,
                  Data(base64Encoded: displayName.ciphertext) != nil else {
                throw KeySetError.malformed("display name")
            }
        }
    }

    // Checks the SSH line has the P-256 type and a base64 blob. The
    // point itself is checked by gitd; this stops an empty file from
    // being published as a member.
    static func hasSSHPublicKey(_ line: String) -> Bool {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, parts[0] == "ecdsa-sha2-nistp256" else {
            return false
        }
        guard let decoded = Data(base64Encoded: parts[1]), decoded.count > 16 else {
            return false
        }
        return true
    }

    static func hasAgePublicKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("age1") && trimmed.count > 8 && !trimmed.contains(where: \.isWhitespace)
    }

    static func displayNameAAD(_ name: String) -> Data {
        var data = Data(displayNameAADPrefix.utf8)
        data.append(Data(name.utf8))
        return data
    }
}

public enum KeySetError: Error, Equatable {
    case malformed(String)
    case displayNameAbsent
    case invalidDisplayName
}
