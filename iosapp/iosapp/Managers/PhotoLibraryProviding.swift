import Foundation
import CoreGraphics
import UIKit
import AVFoundation

// Defines a minimal abstraction over photo library operations.
// Enables unit testing of components like PhotoSyncManager without relying on Photos framework.
protocol PhotoLibraryProviding {
    // Exposes read-access permission state so callers can avoid implicit Photos permission prompts.
    var isAuthorized: Bool { get }
    func requestAuthorization() async -> Bool
    func fetchAllAssets() -> [PhotoAsset]
    // Resolves the original filename lazily so callers can avoid expensive metadata fetches on cache-hit runs.
    func filename(for photoAsset: PhotoAsset) -> String
    func getAssetData(for photoAsset: PhotoAsset) async throws -> Data
    // Resolves a readable file URL for asset bytes so large uploads can stream directly from disk.
    func getAssetFileURL(for photoAsset: PhotoAsset) async throws -> URL
    func generateThumbnail(for photoAsset: PhotoAsset, size: CGSize) async throws -> (data: Data, width: Int, height: Int)
    func generateThumbnailLongestEdge(for photoAsset: PhotoAsset, longestEdge: CGFloat) async throws -> (data: Data, width: Int, height: Int)
    // Attempts to resolve a local library thumbnail without network-backed iCloud fetches.
    // Returns nil when local lookup fails so callers can fall back to remote sources.
    func generateThumbnail(forLocalIdentifier localID: String, size: CGSize) async -> UIImage?
    // Attempts to resolve full-resolution image bytes from a local Photos asset without triggering network fetches.
    // Returns nil when local lookup fails so callers can fall back to remote media sources.
    func getOriginalImageData(forLocalIdentifier localID: String) async -> Data?
    // Attempts to resolve a local video file URL without triggering network-backed iCloud fetches.
    // Returns nil when local lookup fails so callers can fall back to remote streaming.
    func getVideoURL(forLocalIdentifier localID: String) async -> URL?
    func extractMetadata(for photoAsset: PhotoAsset) -> MediaMetadata
}


