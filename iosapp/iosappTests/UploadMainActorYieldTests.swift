import Foundation
import CryptoKit
import GitDB
import Photos
import Testing
@testable import iosapp

// Proves upload preparation leaves the main actor. A main-actor task queued
// first cannot run until the step suspends, so a step that stays on the
// caller finishes with the flag still clear.
@MainActor
@Suite("Upload main-actor yield")
struct UploadMainActorYieldTests {
    private func expectMainActorYielded(
        during work: () async throws -> Void
    ) async rethrows {
        var ran = false
        let marker = Task { @MainActor in
            ran = true
        }
        try await work()
        #expect(ran)
        await marker.value
    }

    @Test func loadAssetsYieldsTheMainActor() async throws {
        let asset = PhotoAsset(
            id: "IMG_YIELD",
            phAsset: nil,
            filename: "yield.jpg",
            creationDate: Date(timeIntervalSince1970: 1),
            modificationDate: nil,
            mediaType: .image
        )
        let manager = PhotoSyncManager(
            photoLibraryProvider: MockPhotoLibraryProvider(assets: [asset]),
            manifestManager: MockManifestManager()
        )
        var loaded: [PhotoAsset] = []
        try await expectMainActorYielded {
            loaded = try await manager.loadAssets()
        }
        #expect(loaded.map(\.id) == ["IMG_YIELD"])
    }

    @Test func hashAssetYieldsTheMainActor() async throws {
        let payload = Data(repeating: 7, count: 256 * 1024)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-yield-\(UUID().uuidString).bin")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let dek = EncryptionUtils.randomKey()
        let expected = try EncryptionUtils.computeStreamingHashes(fileURL: fileURL, dek: dek)
        let manager = PhotoSyncManager(
            photoLibraryProvider: MockPhotoLibraryProvider(),
            manifestManager: MockManifestManager()
        )
        var hashed: (plaintextSHA256: String, encryptedOID: String, encryptedSize: Int64, plaintextSize: Int64)?
        try await expectMainActorYielded {
            hashed = try await manager.hashAsset(fileURL: fileURL, dek: dek)
        }
        let actual = try #require(hashed)
        #expect(actual.plaintextSHA256 == expected.plaintextSHA256)
        #expect(actual.encryptedOID == expected.encryptedOID)
        #expect(actual.encryptedSize == expected.encryptedSize)
        #expect(actual.plaintextSize == expected.plaintextSize)
    }

    @Test func encryptThumbnailYieldsTheMainActor() async throws {
        let data = Data(repeating: 3, count: 8_000)
        let kek = EncryptionUtils.randomKey()
        let manager = PhotoSyncManager(
            photoLibraryProvider: MockPhotoLibraryProvider(),
            manifestManager: MockManifestManager()
        )
        var prepared: (sha256: String, encrypted: Data, wrappedDEK: String)?
        try await expectMainActorYielded {
            prepared = try await manager.encryptThumbnail(data: data, kek: kek, kekEpoch: 1)
        }
        let thumbnail = try #require(prepared)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(thumbnail.sha256 == digest)
        let wrapped = try #require(Data(base64Encoded: thumbnail.wrappedDEK))
        let dek = try EncryptionUtils.unwrapDEK(wrapped, withKEK: kek, kekEpoch: 1)
        let plaintext = try EncryptionUtils.decryptChunkedBinary(
            ciphertext: thumbnail.encrypted,
            dek: dek
        )
        #expect(plaintext == data)
    }
}
