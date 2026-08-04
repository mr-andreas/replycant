import Foundation
import Photos
import AVFoundation
import UIKit

enum PhotoLibraryError: Error {
    case accessDenied
    case assetDataUnavailable
}

// Captures stable PhotoKit identity and timestamps so sync can skip already-uploaded media quickly.
struct PhotoAsset: Identifiable {
    let id: String
    let phAsset: PHAsset?
    let filename: String
    let creationDate: Date?
    let modificationDate: Date?
    let mediaType: PHAssetMediaType
}

struct MediaMetadata {
    let width: Int
    let height: Int
    let takenAt: String?
    let modifiedAt: String?
    let duration: Double?
    let mimeType: String?
    let location: Location?
    let isFavorite: Bool
    let isHidden: Bool
    let burstIdentifier: String?
    
    struct Location {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
    }
}

// Provides access to the device's photo library and media processing operations.
// Implements PhotoLibraryProviding to enable testability through dependency injection.
final class PhotoLibraryManager: PhotoLibraryProviding, @unchecked Sendable {
    // Reports current read authorization so callers can avoid API access that would trigger a permission prompt.
    var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }
    
    func requestAuthorization() async -> Bool {
        log("Requesting photo library authorization...", context: "PhotoLibrary")
        let result = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization { status in
                log("Authorization status: \(status.rawValue)", context: "PhotoLibrary")
                continuation.resume(returning: status == .authorized)
            }
        }
        log("Authorization granted: \(result)", context: "PhotoLibrary")
        return result
    }
    
    // Returns a single newest-first media list so sync prioritizes recent captures.
    func fetchAllAssets() -> [PhotoAsset] {
        log("Fetching all assets...", context: "PhotoLibrary")
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let allVideos = PHAsset.fetchAssets(with: .video, options: fetchOptions)
        
        log("Found \(allPhotos.count) photos and \(allVideos.count) videos", context: "PhotoLibrary")
        
        var assets: [PhotoAsset] = []
        
        allPhotos.enumerateObjects { asset, _, _ in
            assets.append(PhotoAsset(
                id: asset.localIdentifier,
                phAsset: asset,
                filename: "",
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                mediaType: asset.mediaType
            ))
        }
        
        allVideos.enumerateObjects { asset, _, _ in
            assets.append(PhotoAsset(
                id: asset.localIdentifier,
                phAsset: asset,
                filename: "",
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                mediaType: asset.mediaType
            ))
        }
        
        let sorted = Self.sortAssetsForUpload(assets)
        log("Returning \(sorted.count) total assets sorted by creation date", context: "PhotoLibrary")
        return sorted
    }

    // Resolves a stable filename only when callers actually need to upload an asset.
    func filename(for photoAsset: PhotoAsset) -> String {
        if !photoAsset.filename.isEmpty {
            return photoAsset.filename
        }
        guard let phAsset = photoAsset.phAsset else {
            return "asset-\(photoAsset.id)"
        }
        return generateFilename(for: phAsset)
    }

    // Centralizes upload ordering so all callers prioritize newest assets first.
    static func sortAssetsForUpload(_ assets: [PhotoAsset]) -> [PhotoAsset] {
        assets.sorted {
            let leftDate = $0.creationDate ?? Date.distantPast
            let rightDate = $1.creationDate ?? Date.distantPast
            if leftDate == rightDate {
                return $0.id < $1.id
            }
            return leftDate > rightDate
        }
    }
    
    func getAssetData(for photoAsset: PhotoAsset) async throws -> Data {
        log("Fetching data for asset: \(photoAsset.filename) (type: \(photoAsset.mediaType == .image ? "image" : "video"))", context: "PhotoLibrary")
        
        guard let phAsset = photoAsset.phAsset else {
            logError("PHAsset unavailable for: \(photoAsset.filename)", context: "PhotoLibrary")
            throw PhotoLibraryError.assetDataUnavailable
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            
            if photoAsset.mediaType == .image {
                PHImageManager.default().requestImageDataAndOrientation(for: phAsset, options: options) { data, _, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        logError("Error fetching image data: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    guard let data = data else {
                        logError("Image data unavailable for: \(photoAsset.filename)", context: "PhotoLibrary")
                        continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                        return
                    }
                    
                    logDebug("Successfully fetched image data: \(data.count) bytes", context: "PhotoLibrary")
                    continuation.resume(returning: data)
                }
            } else if photoAsset.mediaType == .video {
                let videoOptions = PHVideoRequestOptions()
                videoOptions.version = .original
                videoOptions.deliveryMode = .highQualityFormat
                videoOptions.isNetworkAccessAllowed = true
                
                PHImageManager.default().requestAVAsset(forVideo: phAsset, options: videoOptions) { avAsset, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        logError("Error fetching video asset: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    guard let urlAsset = avAsset as? AVURLAsset else {
                        logError("Video asset unavailable for: \(photoAsset.filename)", context: "PhotoLibrary")
                        continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                        return
                    }
                    
                    do {
                        let data = try Data(contentsOf: urlAsset.url)
                        logDebug("Successfully fetched video data: \(data.count) bytes", context: "PhotoLibrary")
                        continuation.resume(returning: data)
                    } catch {
                        logError("Error reading video data: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                    }
                }
            } else {
                logError("Unsupported media type for: \(photoAsset.filename)", context: "PhotoLibrary")
                continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
            }
        }
    }

    // Resolves asset bytes as a file URL so upload encryption can stream from disk instead of buffering full media in RAM.
    func getAssetFileURL(for photoAsset: PhotoAsset) async throws -> URL {
        log("Resolving file URL for asset: \(photoAsset.filename) (type: \(photoAsset.mediaType == .image ? "image" : "video"))", context: "PhotoLibrary")

        guard let phAsset = photoAsset.phAsset else {
            logError("PHAsset unavailable for file URL: \(photoAsset.filename)", context: "PhotoLibrary")
            throw PhotoLibraryError.assetDataUnavailable
        }

        if photoAsset.mediaType == .video {
            let videoOptions = PHVideoRequestOptions()
            videoOptions.version = .original
            videoOptions.deliveryMode = .highQualityFormat
            videoOptions.isNetworkAccessAllowed = true

            return try await withCheckedThrowingContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: phAsset, options: videoOptions) { avAsset, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        logError("Error fetching video file URL: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let urlAsset = avAsset as? AVURLAsset else {
                        logError("Video asset unavailable for file URL: \(photoAsset.filename)", context: "PhotoLibrary")
                        continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                        return
                    }

                    logDebug("Resolved video file URL: \(urlAsset.url.path)", context: "PhotoLibrary")
                    continuation.resume(returning: urlAsset.url)
                }
            }
        }

        if photoAsset.mediaType == .image {
            let options = PHImageRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            return try await withCheckedThrowingContinuation { continuation in
                PHImageManager.default().requestImageDataAndOrientation(for: phAsset, options: options) { data, _, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        logError("Error fetching image data for file URL: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let data else {
                        logError("Image data unavailable for file URL: \(photoAsset.filename)", context: "PhotoLibrary")
                        continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                        return
                    }

                    do {
                        let fileExtension = URL(fileURLWithPath: photoAsset.filename).pathExtension
                        let fileURL = try self.writeTemporaryAssetFile(data: data, fileExtension: fileExtension)
                        logDebug("Created temporary image file: \(fileURL.lastPathComponent)", context: "PhotoLibrary")
                        continuation.resume(returning: fileURL)
                    } catch {
                        logError("Failed writing temporary image file: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        logError("Unsupported media type for file URL: \(photoAsset.filename)", context: "PhotoLibrary")
        throw PhotoLibraryError.assetDataUnavailable
    }
    
    func generateThumbnail(for photoAsset: PhotoAsset, size: CGSize = CGSize(width: 150, height: 150)) async throws -> (data: Data, width: Int, height: Int) {
        logDebug("Generating thumbnail for: \(photoAsset.filename) at size \(size)", context: "PhotoLibrary")

        if photoAsset.mediaType == .video {
            return try await generateVideoThumbnail(for: photoAsset, size: size)
        } else {
            return try await generateImageThumbnail(for: photoAsset, size: size)
        }
    }

    func generateThumbnailLongestEdge(for photoAsset: PhotoAsset, longestEdge: CGFloat) async throws -> (data: Data, width: Int, height: Int) {
        logDebug("Generating thumbnail for: \(photoAsset.filename) with longest edge: \(longestEdge)", context: "PhotoLibrary")
        
        let metadata = extractMetadata(for: photoAsset)
        let aspectRatio = CGFloat(metadata.width) / CGFloat(metadata.height)
        
        let targetSize: CGSize
        if metadata.width >= metadata.height {
            targetSize = CGSize(width: longestEdge, height: longestEdge / aspectRatio)
        } else {
            targetSize = CGSize(width: longestEdge * aspectRatio, height: longestEdge)
        }
        
        return try await generateThumbnail(for: photoAsset, size: targetSize)
    }

    // Resolves a thumbnail directly from a local Photos asset to avoid LFS fetches when the original is on-device.
    // Uses network-disabled options so iCloud-only assets return nil and callers can intentionally fall back.
    func generateThumbnail(forLocalIdentifier localID: String, size: CGSize) async -> UIImage? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject else {
            logDebug("No local Photos asset for identifier: \(localID)", context: "PhotoLibrary")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.resizeMode = .fast
            options.isSynchronous = false

            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    logWarning("Failed local thumbnail lookup for \(localID): \(error.localizedDescription)", context: "PhotoLibrary")
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: image)
            }
        }
    }

    // Resolves full-resolution image bytes from a local Photos asset so fullscreen rendering can avoid LFS fetches.
    // Uses network-disabled options so iCloud-only assets return nil and callers intentionally fall back.
    func getOriginalImageData(forLocalIdentifier localID: String) async -> Data? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject, asset.mediaType == .image else {
            logDebug("No local Photos image asset for identifier: \(localID)", context: "PhotoLibrary")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    logWarning("Failed local original image lookup for \(localID): \(error.localizedDescription)", context: "PhotoLibrary")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    // Resolves a local video file URL from Photos so fullscreen playback can bypass decryptd when the source exists on-device.
    // Uses network-disabled options so iCloud-only assets return nil and callers intentionally fall back.
    func getVideoURL(forLocalIdentifier localID: String) async -> URL? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard let asset = assets.firstObject, asset.mediaType == .video else {
            logDebug("No local Photos video asset for identifier: \(localID)", context: "PhotoLibrary")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = false

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    logWarning("Failed local video URL lookup for \(localID): \(error.localizedDescription)", context: "PhotoLibrary")
                    continuation.resume(returning: nil)
                    return
                }
                let url = (avAsset as? AVURLAsset)?.url
                continuation.resume(returning: url)
            }
        }
    }
    
    private func generateImageThumbnail(for photoAsset: PhotoAsset, size: CGSize) async throws -> (data: Data, width: Int, height: Int) {
        logDebug("Generating image thumbnail for: \(photoAsset.filename)", context: "PhotoLibrary")

        guard let phAsset = photoAsset.phAsset else {
            logError("PHAsset unavailable for thumbnail: \(photoAsset.filename)", context: "PhotoLibrary")
            throw PhotoLibraryError.assetDataUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .exact

            PHImageManager.default().requestImage(for: phAsset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    logError("Error generating image thumbnail: \(error.localizedDescription)", context: "PhotoLibrary")
                    continuation.resume(throwing: error)
                    return
                }

                guard let image = image else {
                    logError("Image thumbnail generation failed for: \(photoAsset.filename)", context: "PhotoLibrary")
                    continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                    return
                }

                guard let cgImage = image.cgImage else {
                    logError("Failed to get CGImage from UIImage", context: "PhotoLibrary")
                    continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                    return
                }

                guard let jpegData = self.createJPEGData(from: cgImage, compressionQuality: 0.8) else {
                    logError("Failed to convert image thumbnail to JPEG", context: "PhotoLibrary")
                    continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                    return
                }

                let actualWidth = Int(image.size.width * image.scale)
                let actualHeight = Int(image.size.height * image.scale)

                logDebug("Image thumbnail generated: \(actualWidth)x\(actualHeight), \(jpegData.count) bytes", context: "PhotoLibrary")
                continuation.resume(returning: (jpegData, actualWidth, actualHeight))
            }
        }
    }
    
    private func generateVideoThumbnail(for photoAsset: PhotoAsset, size: CGSize) async throws -> (data: Data, width: Int, height: Int) {
        logDebug("Generating video thumbnail for: \(photoAsset.filename)", context: "PhotoLibrary")

        guard let phAsset = photoAsset.phAsset else {
            logError("PHAsset unavailable for video thumbnail: \(photoAsset.filename)", context: "PhotoLibrary")
            throw PhotoLibraryError.assetDataUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let videoOptions = PHVideoRequestOptions()
            videoOptions.version = .original
            videoOptions.deliveryMode = .highQualityFormat
            videoOptions.isNetworkAccessAllowed = true

            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: videoOptions) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    logError("Error fetching video asset for thumbnail: \(error.localizedDescription)", context: "PhotoLibrary")
                    continuation.resume(throwing: error)
                    return
                }

                guard let urlAsset = avAsset as? AVURLAsset else {
                    logError("Video asset unavailable for thumbnail generation: \(photoAsset.filename)", context: "PhotoLibrary")
                    continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                    return
                }
                
                let imageGenerator = AVAssetImageGenerator(asset: urlAsset)
                imageGenerator.appliesPreferredTrackTransform = true
                imageGenerator.maximumSize = size
                imageGenerator.requestedTimeToleranceAfter = .zero
                imageGenerator.requestedTimeToleranceBefore = .zero
                
                // Try to get thumbnail from the middle of the video, or from the beginning if duration is unknown
                Task {
                    do {
                        let duration = try await urlAsset.load(.duration)
                        let time = CMTime(seconds: max(0.1, duration.seconds / 2), preferredTimescale: duration.timescale)
                        
                        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, error in
                    if let error = error {
                        logError("Error generating video thumbnail: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let cgImage = cgImage else {
                        logError("Video thumbnail generation failed - no image generated for: \(photoAsset.filename)", context: "PhotoLibrary")
                        continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                        return
                    }

                    // Resize to exact target size while maintaining aspect ratio
                    let resizedImage = self.resizeCGImage(cgImage, to: size)

                    guard let jpegData = self.createJPEGData(from: resizedImage, compressionQuality: 0.8) else {
                        logError("Failed to convert video thumbnail to JPEG", context: "PhotoLibrary")
                        continuation.resume(throwing: PhotoLibraryError.assetDataUnavailable)
                        return
                    }

                    let actualWidth = Int(resizedImage.width)
                    let actualHeight = Int(resizedImage.height)

                            logDebug("Video thumbnail generated: \(actualWidth)x\(actualHeight), \(jpegData.count) bytes", context: "PhotoLibrary")
                            continuation.resume(returning: (jpegData, actualWidth, actualHeight))
                        }
                    } catch {
                        logError("Error loading video duration: \(error.localizedDescription)", context: "PhotoLibrary")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func resizeCGImage(_ cgImage: CGImage, to targetSize: CGSize) -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        
        let widthRatio = targetSize.width / CGFloat(width)
        let heightRatio = targetSize.height / CGFloat(height)
        let scaleFactor = min(widthRatio, heightRatio)
        
        let scaledWidth = Int(CGFloat(width) * scaleFactor)
        let scaledHeight = Int(CGFloat(height) * scaleFactor)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: scaledWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        context?.interpolationQuality = .high
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        
        return context?.makeImage() ?? cgImage
    }
    
    private func createJPEGData(from cgImage: CGImage, compressionQuality: CGFloat) -> Data? {
        let mutableData = CFDataCreateMutable(nil, 0)
        guard let destination = CGImageDestinationCreateWithData(mutableData!, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        CGImageDestinationFinalize(destination)
        
        return mutableData as Data?
    }

    // Persists image bytes into a managed temp file so upload paths can treat image and video sources uniformly as URLs.
    private func writeTemporaryAssetFile(data: Data, fileExtension: String) throws -> URL {
        let safeExtension = fileExtension.isEmpty ? "bin" : fileExtension
        let filename = "replycant-upload-\(UUID().uuidString).\(safeExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
    
    func extractMetadata(for photoAsset: PhotoAsset) -> MediaMetadata {
        guard let asset = photoAsset.phAsset else {
            // Return default metadata when PHAsset is unavailable (e.g., in tests)
            return MediaMetadata(
                width: 0,
                height: 0,
                takenAt: nil,
                modifiedAt: nil,
                duration: nil,
                mimeType: nil,
                location: nil,
                isFavorite: false,
                isHidden: false,
                burstIdentifier: nil
            )
        }
        
        let dateFormatter = ISO8601DateFormatter()
        let takenAt = asset.creationDate.map { dateFormatter.string(from: $0) }
        let modifiedAt = asset.modificationDate.map { dateFormatter.string(from: $0) }
        
        let location: MediaMetadata.Location?
        if let assetLocation = asset.location {
            location = MediaMetadata.Location(
                latitude: assetLocation.coordinate.latitude,
                longitude: assetLocation.coordinate.longitude,
                altitude: assetLocation.altitude
            )
        } else {
            location = nil
        }
        
        let resources = PHAssetResource.assetResources(for: asset)
        let mimeType = resources.first?.uniformTypeIdentifier
        
        let duration: Double?
        if asset.mediaType == .video {
            duration = asset.duration
        } else {
            duration = nil
        }
        
        logDebug("Extracted metadata - Size: \(asset.pixelWidth)x\(asset.pixelHeight), Duration: \(duration ?? 0)s, Location: \(location != nil ? "Yes" : "No"), Favorite: \(asset.isFavorite)", context: "PhotoLibrary")
        
        return MediaMetadata(
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            takenAt: takenAt,
            modifiedAt: modifiedAt,
            duration: duration,
            mimeType: mimeType,
            location: location,
            isFavorite: asset.isFavorite,
            isHidden: asset.isHidden,
            burstIdentifier: asset.burstIdentifier
        )
    }
    
    private func generateFilename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        
        if let resource = resources.first {
            let originalFilename = resource.originalFilename
            
            if originalFilename.contains(".") {
                return originalFilename
            }
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = asset.creationDate.map { dateFormatter.string(from: $0) } ?? "unknown"
        
        let type = asset.mediaType == .video ? "video" : "photo"
        let ext = asset.mediaType == .video ? "mp4" : "jpg"
        
        return "\(dateString)_\(type)_\(asset.localIdentifier.prefix(8)).\(ext)"
    }
}

