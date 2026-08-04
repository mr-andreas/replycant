import Foundation
import GitDB

typealias ThumbnailSetManifest = AppThumbnailSetManifest

// Defines one ThumbnailSet manifest that groups every derived thumbnail for one Original.
struct AppThumbnailSetManifest: Codable, Manifest {
    static var apiVersion: String { "media.replycant.com/v1alpha1" }
    static var kind: String { "ThumbnailSet" }

    let apiVersion: String
    let kind: String
    var metadata: Metadata
    var spec: Spec
    var status: Status

    var id: String { metadata.name }

    enum CodingKeys: String, CodingKey {
        case apiVersion
        case kind
        case metadata
        case spec
        case status
    }

    struct Metadata: Codable, ManifestMetadata {
        let name: String
        let deviceSpace: String
    }

    struct Spec: Codable {
        let originalRef: String
        let thumbnails: [Entry]

        struct Entry: Codable, Equatable {
            let name: String
            let sha256: String
            let width: Int
            let height: Int
            let filesize: Int64
        }
    }

    struct Status: Codable {}

    init(originalRef: String, thumbnails: [Spec.Entry], name: String, deviceSpace: String) {
        self.apiVersion = Self.apiVersion
        self.kind = Self.kind
        self.metadata = Metadata(name: name, deviceSpace: deviceSpace)
        self.spec = Spec(originalRef: originalRef, thumbnails: thumbnails)
        self.status = Status()
    }
}

extension ThumbnailSetManifest {
    init(
        originalRef: String,
        thumbnails: [Spec.Entry],
        name: String,
        deviceSpace: String? = nil
    ) {
        self.init(
            originalRef: originalRef,
            thumbnails: thumbnails,
            name: name,
            deviceSpace: deviceSpace ?? DeviceIdentifierManager.shared.deviceSpaceIdentifier
        )
    }
}
