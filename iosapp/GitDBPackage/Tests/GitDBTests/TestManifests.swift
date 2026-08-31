import Foundation
@testable import GitDB

// Provides test-only manifest schemas used to verify GitDB's schema-agnostic behavior.
struct TestOriginalManifest: Codable, Manifest {
    static var apiVersion: String { "test.replycant.dev/v1" }
    static var kind: String { "Original" }

    let apiVersion: String
    let kind: String
    let metadata: Metadata
    let spec: Spec
    let status: Status

    var id: String { spec.id }

    struct Metadata: Codable, ManifestMetadata {
        let name: String
        let deviceSpace: String
    }

    struct Spec: Codable {
        let id: String
        let sha256: String
        let guessedTakenAt: Date?
    }

    struct Status: Codable {}

    init(id: String, deviceSpace: String = "device-a", guessedTakenAt: Date?, sha256: String) {
        self.apiVersion = Self.apiVersion
        self.kind = Self.kind
        self.metadata = Metadata(name: id, deviceSpace: deviceSpace)
        self.spec = Spec(id: id, sha256: sha256, guessedTakenAt: guessedTakenAt)
        self.status = Status()
    }
}

// Provides test-only thumbnail-set schema for multi-kind mutation coverage.
struct TestThumbnailSetManifest: Codable, Manifest {
    static var apiVersion: String { "test.replycant.dev/v1" }
    static var kind: String { "ThumbnailSet" }

    let apiVersion: String
    let kind: String
    let metadata: Metadata
    let spec: Spec
    let status: Status

    var id: String { metadata.name }

    struct Metadata: Codable, ManifestMetadata {
        let name: String
        let deviceSpace: String
    }

    struct Spec: Codable {
        let originalRef: String
        let thumbnails: [Entry]
    }

    struct Entry: Codable {
        let name: String
    }

    struct Status: Codable {}

    init(id: String, deviceSpace: String = "device-a", originalRef: String) {
        self.apiVersion = Self.apiVersion
        self.kind = Self.kind
        self.metadata = Metadata(name: id, deviceSpace: deviceSpace)
        self.spec = Spec(
            originalRef: originalRef,
            thumbnails: [Entry(name: "\(id)-thumb-150x150")]
        )
        self.status = Status()
    }
}

// Builds a registry matching legacy Original/Thumbnail query columns used by tests.
func makeTestRegistry() -> ManifestRegistry {
    let registry = ManifestRegistry()
    registry.register(TestOriginalManifest.self) { reg in
        reg.column("guessedTakenAt", type: .real, nullable: true)
        reg.column("sha256", type: .text)
        reg.index(on: ["guessedTakenAt", "id"], where: "guessedTakenAt IS NOT NULL")
        reg.index(on: ["sha256"])
        reg.extractColumns { manifest in
            [
                "guessedTakenAt": manifest.spec.guessedTakenAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                "sha256": .string(manifest.spec.sha256),
            ]
        }
    }
    registry.register(TestThumbnailSetManifest.self) { reg in
        reg.column("originalRef", type: .text)
        reg.index(on: ["originalRef"])
        reg.extractColumns { manifest in
            [
                "originalRef": .string(manifest.spec.originalRef),
            ]
        }
    }
    return registry
}

// Deterministic test KEK so package tests can encrypt fixtures without age identity.
let testManifestKEK = Data(repeating: 0x42, count: 32)

// Produces fixture YAML for sync tests that run through registry-backed decoding.
func testOriginalManifestYAML(id: String, guessedTakenAt: String?) -> String {
    let guessedLine = guessedTakenAt.map { "  guessedTakenAt: \($0)\n" } ?? ""
    return """
    apiVersion: \(TestOriginalManifest.apiVersion)
    kind: \(TestOriginalManifest.kind)
    metadata:
      name: \(id)
      deviceSpace: test-device
    spec:
      id: \(id)
      sha256: sha-\(id)
    \(guessedLine)status: {}
    """
}

// Wraps plaintext YAML in a REPLYCANT-ENC-V1 envelope so sync tests exercise real decrypt paths.
func encryptTestManifestYAML(_ yaml: String, kek: Data = testManifestKEK, epoch: Int = 1) throws -> String {
    let encrypted = try EncryptionUtils.encryptAESGCM(plaintext: Data(yaml.utf8), key: kek)
    let encodedPayload = encrypted.base64EncodedString()
    return """
    REPLYCANT-ENC-V1
    kek-epoch: \(epoch)
    ---
    \(encodedPayload)
    """
}

// Placeholder epoch file so preloadAllKEKs discovers epoch 1; content is unused when KEK is injected.
let testEpochPlaceholderFiles: [(String, String)] = [
    ("gitdb/version", "1\n"),
    ("encryption/current", "1\n"),
    ("encryption/epochs/1.age", "placeholder\n"),
]
