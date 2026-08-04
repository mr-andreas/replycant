import Foundation
import ImageIO
import Testing
@testable import iosapp

// Verifies sanitized screenshot media remains privacy-safe and keeps fixture geometry stable over time.
struct ScreenshotMediaTests {
    // Resolves the app-consumed screenshot media so privacy checks validate the
    // same files Xcode bundles for screenshot fixture runs.
    private func sourceScreenshotMedia() throws -> [TestSupport.ScreenshotFixturePhoto] {
        let fileURL = URL(fileURLWithPath: #filePath)
        let projectRoot = fileURL
            .deletingLastPathComponent() // iosappTests
            .deletingLastPathComponent() // iosapp
        let mediaDirectory = projectRoot
            .appendingPathComponent("iosapp", isDirectory: true)
            .appendingPathComponent("ScreenshotMedia", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "jpg" || ext == "jpeg"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try urls.map { url in
            let data = try Data(contentsOf: url)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            return TestSupport.ScreenshotFixturePhoto(
                name: url.lastPathComponent,
                data: data,
                width: width,
                height: height
            )
        }
    }

    // Ensures bundled screenshot photos do not carry EXIF/GPS device metadata that could leak private information.
    @Test
    func screenshotMediaStripsSensitiveMetadata() throws {
        let photos = try sourceScreenshotMedia()
        #expect(photos.isEmpty == false)

        for photo in photos {
            guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                Issue.record("Failed to decode image properties for \(photo.name)")
                continue
            }

            #expect(props[kCGImagePropertyGPSDictionary] == nil)
            #expect(props[kCGImagePropertyExifDictionary] == nil)

            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                #expect(tiff[kCGImagePropertyTIFFMake] == nil)
                #expect(tiff[kCGImagePropertyTIFFModel] == nil)
            }
        }
    }

    // Ensures screenshot fixture entry generation spans multiple months for visible month-sidebar navigation.
    @Test
    func screenshotFixtureEntriesSpanMultipleMonths() {
        let entries = TestSupport.screenshotFixtureEntries(photoCount: 5, totalPhotoEntries: 47)
        #expect(entries.count == 47)
        #expect(entries.allSatisfy { $0.sourceIndex >= 0 && $0.sourceIndex < 5 })

        let parser = ISO8601DateFormatter()
        let calendar = Calendar(identifier: .gregorian)
        let months = Set(entries.compactMap { entry -> String? in
            guard let date = parser.date(from: entry.timestamp) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { return nil }
            return "\(year)-\(month)"
        })

        #expect(months.count >= 6)
    }

    // Ensures screenshot thumbnail variants keep the expected square and long-edge sizing contracts.
    @Test
    func screenshotThumbnailDimensionsMatchExpectedContracts() throws {
        let photo = try #require(sourceScreenshotMedia().first)
        let dimensions = TestSupport.screenshotThumbnailDimensions(for: photo.data)
        #expect(dimensions.count == 3)

        let small = try #require(dimensions.first { $0.name == "150x150" })
        #expect(small.width == 150)
        #expect(small.height == 150)

        let medium = try #require(dimensions.first { $0.name == "225x225" })
        #expect(medium.width == 225)
        #expect(medium.height == 225)

        let large = try #require(dimensions.first { $0.name == "1024" })
        #expect(max(large.width, large.height) == 1024)
    }

    // Prevents fixture-source drift by enforcing a single committed media
    // location under the app directory Xcode consumes.
    @Test
    func screenshotMediaHasSingleCommittedSourceDirectory() {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent() // iosappTests
            .deletingLastPathComponent() // iosapp
            .deletingLastPathComponent() // repo root
        let duplicateDirectory = repoRoot
            .appendingPathComponent("iosapp", isDirectory: true)
            .appendingPathComponent("ScreenshotMedia", isDirectory: true)

        #expect(FileManager.default.fileExists(atPath: duplicateDirectory.path) == false)
    }

    // Ensures fixture discovery still works when Xcode flattens ScreenshotMedia into the bundle root.
    @Test
    func screenshotMediaURLsAcceptFlattenedAndNestedLayouts() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-media-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let nestedRoot = tempRoot.appendingPathComponent("nested", isDirectory: true)
        let nestedMedia = nestedRoot.appendingPathComponent("ScreenshotMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedMedia, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: nestedMedia.appendingPathComponent("demo-01.jpg"))

        let flattenedRoot = tempRoot.appendingPathComponent("flattened", isDirectory: true)
        try FileManager.default.createDirectory(at: flattenedRoot, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: flattenedRoot.appendingPathComponent("demo-02.jpg"))

        let nestedURLs = try TestSupport.screenshotMediaURLs(in: nestedRoot)
        #expect(nestedURLs.map(\.lastPathComponent) == ["demo-01.jpg"])

        let flattenedURLs = try TestSupport.screenshotMediaURLs(in: flattenedRoot)
        #expect(flattenedURLs.map(\.lastPathComponent) == ["demo-02.jpg"])
    }
}
