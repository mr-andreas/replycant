import Foundation

// Paths inside a library. The space name in the path is the only
// place a reader learns which key set an object belongs to.
public enum EncryptionLayout {
    public static let spacesPrefix = "encryptionspaces"
    public static let globalRoot = "encryption"

    public static func manifestPath(
        space: String,
        apiVersion: String,
        kind: String,
        name: String
    ) -> String {
        "\(spacesPrefix)/\(space)/manifests/\(apiVersion)/\(kind)/\(shardName(name)).yaml"
    }

    public static func binaryPath(
        space: String,
        apiVersion: String,
        kind: String,
        name: String
    ) -> String {
        "\(spacesPrefix)/\(space)/binary/\(apiVersion)/\(kind)/\(shardName(name))"
    }

    public static func spaceKeySetRoot(_ space: String) -> String {
        "\(spacesPrefix)/\(space)/encryption"
    }

    // Returns the space that owns this path. Key material and files
    // that sit directly under a space are not objects of that space.
    public static func space(from path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == spacesPrefix else {
            return nil
        }
        guard parts[2] == "manifests" || parts[2] == "binary" else {
            return nil
        }
        guard !parts[1].isEmpty else {
            return nil
        }
        return parts[1]
    }

    // Readers take the space from the path, including when an older
    // file still carries a deviceSpace field or a new file omits it.
    public static func yamlAssigningSpace(_ space: String, to yaml: String) -> String {
        var lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("deviceSpace:") }) {
            let indent = lines[index].prefix { $0 == " " }
            lines[index] = "\(indent)deviceSpace: \(space)"
            return lines.joined(separator: "\n")
        }
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:") }) {
            lines.insert("  deviceSpace: \(space)", at: index + 1)
            return lines.joined(separator: "\n")
        }
        return yaml
    }
}

// Stops sync when a key set this client opens is not what it claims.
// The apps keep running so the message stays on screen.
public struct EncryptionIntegrityError: Error, Equatable, LocalizedError {
    public let space: String
    public let path: String
    public let reason: String

    public init(space: String, path: String, reason: String) {
        self.space = space
        self.path = path
        self.reason = reason
    }

    public var errorDescription: String? {
        "Could not open \(space) (\(path)): \(reason)."
    }
}
