import Foundation
import GitDB

public typealias ManifestMetadata = GitDB.ManifestMetadata
public typealias Manifest = GitDB.Manifest
typealias OriginalManifest = AppOriginalManifest

// Defines the app-specific Original manifest schema stored in GitDB.
struct AppOriginalManifest: Codable, Manifest {
    static var apiVersion: String { "media.replycant.com/v1alpha1" }
    static var kind: String { "Original" }

    let apiVersion: String
    let kind: String
    var metadata: Metadata
    var spec: Spec
    var status: Status

    var id: String { spec.id }

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
        let id: String
        let localID: String?
        let sha256: String
        let path: String
        let filesize: Int64
        let mediaType: String
        let width: Int
        let height: Int
        let modifiedAt: String?
        let duration: Double?
        let mimeType: String?
        let location: Location?
        let isFavorite: Bool
        let isHidden: Bool
        let burstIdentifier: String?
        let createdAt: Date
        let takenAt: Date?
        let clientCTime: Date?
        let guessedTakenAt: Date?

        struct Location: Codable {
            let latitude: Double
            let longitude: Double
            let altitude: Double?

            init(latitude: Double, longitude: Double, altitude: Double?) {
                self.latitude = latitude
                self.longitude = longitude
                self.altitude = altitude
            }
        }
    }

    struct Status: Codable {}

    init(
        id: String,
        localID: String?,
        sha256: String,
        path: String,
        filesize: Int64,
        name: String,
        deviceSpace: String,
        mediaType: String,
        width: Int,
        height: Int,
        modifiedAt: String?,
        duration: Double?,
        mimeType: String?,
        location: Spec.Location?,
        isFavorite: Bool,
        isHidden: Bool,
        burstIdentifier: String?,
        createdAt: Date = Date(),
        takenAt: Date? = nil,
        clientCTime: Date? = nil,
        guessedTakenAt: Date? = nil
    ) {
        self.apiVersion = Self.apiVersion
        self.kind = Self.kind
        self.metadata = Metadata(name: name, deviceSpace: deviceSpace)
        self.spec = Spec(
            id: id,
            localID: localID,
            sha256: sha256,
            path: path,
            filesize: filesize,
            mediaType: mediaType,
            width: width,
            height: height,
            modifiedAt: modifiedAt,
            duration: duration,
            mimeType: mimeType,
            location: location,
            isFavorite: isFavorite,
            isHidden: isHidden,
            burstIdentifier: burstIdentifier,
            createdAt: createdAt,
            takenAt: takenAt,
            clientCTime: clientCTime,
            guessedTakenAt: guessedTakenAt
        )
        self.status = Status()
    }
}

extension OriginalManifest {
    init(
        id: String,
        localID: String?,
        sha256: String,
        path: String,
        filesize: Int64,
        name: String,
        deviceSpace: String? = nil,
        mediaType: String,
        width: Int,
        height: Int,
        modifiedAt: String?,
        duration: Double?,
        mimeType: String?,
        location: Spec.Location?,
        isFavorite: Bool,
        isHidden: Bool,
        burstIdentifier: String?,
        createdAt: Date = Date(),
        takenAt: Date? = nil,
        clientCTime: Date? = nil,
        guessedTakenAt: Date? = nil
    ) {
        self.init(
            id: id,
            localID: localID,
            sha256: sha256,
            path: path,
            filesize: filesize,
            name: name,
            deviceSpace: deviceSpace ?? DeviceIdentifierManager.shared.deviceSpaceIdentifier,
            mediaType: mediaType,
            width: width,
            height: height,
            modifiedAt: modifiedAt,
            duration: duration,
            mimeType: mimeType,
            location: location,
            isFavorite: isFavorite,
            isHidden: isHidden,
            burstIdentifier: burstIdentifier,
            createdAt: createdAt,
            takenAt: takenAt,
            clientCTime: clientCTime,
            guessedTakenAt: guessedTakenAt
        )
    }
}

