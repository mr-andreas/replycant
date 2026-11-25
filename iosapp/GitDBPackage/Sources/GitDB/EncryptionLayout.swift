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
