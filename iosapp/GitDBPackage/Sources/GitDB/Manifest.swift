import Foundation

// Defines the minimum metadata every manifest must expose for storage namespacing.
public protocol ManifestMetadata: Codable {
    var name: String { get }
    var deviceSpace: String { get }
}

// Defines the common shape GitDB needs to route and store manifests without schema knowledge.
public protocol Manifest: Codable {
    associatedtype Metadata: ManifestMetadata

    var id: String { get }
    var metadata: Metadata { get }

    static var apiVersion: String { get }
    static var kind: String { get }
}

// Exposes static manifest identifiers through existential values used by generic GitDB paths.
public extension Manifest {
    var apiVersionValue: String { Self.apiVersion }
    var kindValue: String { Self.kind }
    var deviceSpaceValue: String { metadata.deviceSpace }
}
