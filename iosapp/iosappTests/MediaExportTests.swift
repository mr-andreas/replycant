import Foundation
import Network
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import iosapp

// Checks that a shared or saved original keeps the bytes the library
// stored, and that a video download asks decryptd for the plaintext
// object rather than a transcode.
@MainActor
@Suite("Media Export Tests", .serialized)
struct MediaExportTests {
    // Builds a timeline item with the path and type the export name
    // and byte checks need. takenAt is required because timeline items
    // sort by capture time.
    private func makeItem(
        id: String = "item-1",
        localID: String? = "local-1",
        path: String = "DCIM/IMG_0001.JPG",
        name: String = "item-1",
        mimeType: String? = "image/jpeg",
        mediaType: String = "photo",
        filesize: Int64 = 1024
    ) -> TimelineItem {
        let manifest = OriginalManifest(
            id: id,
            localID: localID,
            sha256: "sha-\(id)",
            path: path,
            filesize: filesize,
            name: name,
            deviceSpace: "device-space-1",
            mediaType: mediaType,
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: mediaType == "video" ? 3 : nil,
            mimeType: mimeType,
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(),
            takenAt: Date(),
            clientCTime: nil,
            guessedTakenAt: Date()
        )
        return TimelineItem(original: manifest)
    }

    // Keeps the camera file name so a shared photo is recognizable
    // in the destination app.
    @Test func exportFileNameKeepsOriginalName() {
        let item = makeItem(
            path: "/var/mobile/Media/DCIM/100APPLE/IMG_0001.HEIC",
            name: "manifest-name",
            mimeType: "image/heic"
        )
        #expect(MediaExport.exportFileName(for: item) == "IMG_0001.HEIC")
    }

    // A path with no extension cannot be shared as a typed file, so
    // the name comes from the manifest and the type from the MIME.
    @Test func exportFileNameFallsBackWhenPathHasNoExtension() {
        let item = makeItem(path: "no-extension", name: "photo-id", mimeType: "image/jpeg")
        let expected = UTType(mimeType: "image/jpeg")?.preferredFilenameExtension
        #expect(MediaExport.exportFileName(for: item) == "photo-id.\(expected ?? "")")
    }

    // An empty original path still needs a file name the share sheet
    // can hand to another app.
    @Test func exportFileNameFallsBackWhenPathMissing() {
        let item = makeItem(path: "", name: "clip", mimeType: "video/quicktime", mediaType: "video")
        let expected = UTType(mimeType: "video/quicktime")?.preferredFilenameExtension
        #expect(MediaExport.exportFileName(for: item) == "clip.\(expected ?? "")")
    }

    // The original path is a device path, not a path we control.
    // Using it whole would let `..` write outside the temp folder.
    @Test func exportFileNameDropsParentTraversal() {
        let withExtension = makeItem(path: "../x.jpg", name: "ignored", mimeType: "image/jpeg")
        #expect(MediaExport.exportFileName(for: withExtension) == "x.jpg")

        let bare = makeItem(path: "../x", name: "photo", mimeType: "image/jpeg")
        let bareName = MediaExport.exportFileName(for: bare)
        let expected = UTType(mimeType: "image/jpeg")?.preferredFilenameExtension ?? ""
        #expect(bareName == "photo.\(expected)")
        #expect(!bareName.contains(".."))
        #expect(!bareName.contains("/"))
    }

    // Saving and sharing must not re-encode. A changed byte would
    // also make photo sync upload the camera-roll copy as a new item.
    @Test func photoExportWritesSourceBytesUnchanged() async throws {
        let previous = CacheSettingsManager.shared.localThumbnailsEnabled
        CacheSettingsManager.shared.localThumbnailsEnabled = true
        defer { CacheSettingsManager.shared.localThumbnailsEnabled = previous }

        let source = Data([0x00, 0xFF, 0x10, 0x20, 0x30, 0x7F])
        let mockLibrary = MockPhotoLibraryProvider()
        mockLibrary.isAuthorized = true
        mockLibrary.localOriginalImageData["local-1"] = source
        let manager = TimelineManager(photoLibrary: mockLibrary, notificationCenter: NotificationCenter())
        let item = makeItem(localID: "local-1", path: "DCIM/IMG_0001.JPG")

        let url = try await MediaExport.exportOriginal(item: item, timelineManager: manager)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let written = try Data(contentsOf: url)
        #expect(written == source)
        #expect(url.lastPathComponent == "IMG_0001.JPG")
        #expect(url.deletingLastPathComponent().path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    // A downloaded video has to be the original object, with the
    // per-object key the server needs to stream plaintext.
    @Test func videoDownloadRequestTargetsDecryptdObject() throws {
        let url = try FullResolutionImageLoader.makePlaybackURL(
            playbackMethod: .directPlay,
            objectID: "abc123",
            duration: 12,
            isUITesting: false,
            lfsURLString: nil,
            gitURLString: "https://git.example.com"
        )
        let request = MediaExport.makeVideoDownloadRequest(url: url, dekBase64: "DEK-VALUE")
        #expect(request.url?.path == "/decryptd/objects/abc123")
        #expect(request.value(forHTTPHeaderField: "X-Replycant-DEK") == "DEK-VALUE")
    }

    // The ring uses the response length when decryptd sends one.
    @Test func downloadFractionUsesResponseLength() {
        let fraction = MediaExport.downloadFraction(written: 50, expected: 100, fallbackTotal: 999)
        #expect(fraction == 0.5)
    }

    // Some responses omit Content-Length. The manifest size is what
    // the user was already shown for that video.
    @Test func downloadFractionFallsBackToFileSize() {
        let fraction = MediaExport.downloadFraction(written: 25, expected: -1, fallbackTotal: 100)
        #expect(fraction == 0.25)
    }

    // A server that reports more bytes than the length must not draw
    // a ring past a full circle.
    @Test func downloadFractionClampsAtOne() {
        let fraction = MediaExport.downloadFraction(written: 150, expected: 100, fallbackTotal: 100)
        #expect(fraction == 1)
    }

    // Without either length the ring stays empty instead of dividing
    // by zero or jumping to full.
    @Test func downloadFractionIsZeroWithoutTotal() {
        let fraction = MediaExport.downloadFraction(written: 10, expected: -1, fallbackTotal: 0)
        #expect(fraction == 0)
    }

    // The ring is drawn from these callbacks. A download that only
    // reports when it is already finished never shows one.
    @Test func downloadReportsIntermediateProgress() async throws {
        let body = Data(repeating: 0xAB, count: 256 * 1024)
        let fractions = try await downloadFractions(body: body, includeContentLength: true)
        #expect(fractions.contains { $0 > 0 && $0 < 1 }, "fractions \(fractions)")
        #expect(fractions.last == 1, "fractions \(fractions)")
    }

    // decryptd normally sends a length. When it does not, the ring
    // still has to move, using the size already stored on the item.
    @Test func downloadProgressUsesFileSizeWhenLengthMissing() async throws {
        let body = Data(repeating: 0xCD, count: 256 * 1024)
        let fractions = try await downloadFractions(body: body, includeContentLength: false)
        #expect(fractions.contains { $0 > 0 && $0 < 1 }, "fractions \(fractions)")
        #expect(fractions.last == 1, "fractions \(fractions)")
    }

    // A custom URLProtocol hands URLSession the whole body at once, so
    // the task counters never sit between 0 and 1. A loopback server
    // writes the body in pieces, the way decryptd's response does.
    private func downloadFractions(body: Data, includeContentLength: Bool) async throws -> [Double] {
        let server = TrickleDownloadServer(body: body, includeContentLength: includeContentLength)
        try server.start()
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-progress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        var fractions: [Double] = []
        let lock = NSLock()
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/objects/abc"))
        try await MediaExport.downloadVideo(
            request: URLRequest(url: url),
            to: destination,
            fallbackTotal: Int64(body.count),
            onProgress: { fraction in
                lock.lock()
                fractions.append(fraction)
                lock.unlock()
            },
            session: session
        )
        let written = try Data(contentsOf: destination)
        #expect(written == body)
        return fractions
    }
}

// Writes one HTTP body in a few delayed pieces. The pauses are what
// give URLSession a chance to publish a fraction before the file is
// complete, which a single write on loopback does not.
final class TrickleDownloadServer: @unchecked Sendable {
    let body: Data
    let includeContentLength: Bool
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "trickle-download-server")

    init(body: Data, includeContentLength: Bool) {
        self.body = body
        self.includeContentLength = includeContentLength
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        ready.wait()
        if let failure { throw failure }
        port = listener.port?.rawValue ?? 0
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.sendResponse(on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.readRequest(on: connection, buffer: buffer)
        }
    }

    private func sendResponse(on connection: NWConnection) {
        let pieceCount = 4
        let pieceSize = max(1, (body.count + pieceCount - 1) / pieceCount)
        var pieces: [Data] = []
        var offset = 0
        while offset < body.count {
            let end = min(offset + pieceSize, body.count)
            pieces.append(body.subdata(in: offset..<end))
            offset = end
        }
        var messages: [Data] = []
        if includeContentLength {
            let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            messages.append(Data(header.utf8))
            messages.append(contentsOf: pieces)
        } else {
            // No length means the body ends at the chunked terminator.
            // Resetting the socket instead makes URLSession treat a
            // finished download as a failure and skip the final fraction.
            let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            messages.append(Data(header.utf8))
            for piece in pieces {
                var chunk = Data(String(format: "%X\r\n", piece.count).utf8)
                chunk.append(piece)
                chunk.append(Data("\r\n".utf8))
                messages.append(chunk)
            }
            messages.append(Data("0\r\n\r\n".utf8))
        }
        send(messages, index: 0, on: connection)
    }

    private func send(_ messages: [Data], index: Int, on connection: NWConnection) {
        guard index < messages.count else {
            connection.cancel()
            return
        }
        connection.send(content: messages[index], completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.queue.asyncAfter(deadline: .now() + 0.08) {
                self.send(messages, index: index + 1, on: connection)
            }
        })
    }
}
