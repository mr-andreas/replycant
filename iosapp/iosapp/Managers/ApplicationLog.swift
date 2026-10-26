import Foundation

/// Keeps diagnostic lines on disk so Settings can show and share them
/// after unified logging has dropped info-level messages.
enum ApplicationLog {
    static let shareFileName = "replycant-log.txt"

    /// Newest bytes retained. A longer history would make the shared
    /// text file too large to attach comfortably.
    static let maxRetainedBytes = 8 * 1024 * 1024

    private static let lock = NSRecursiveLock()
    private static var directoryOverride: URL?
    private static var maxBytesOverride: Int?

    /// Appends one already-formatted line. Safe from any thread because
    /// git, playback, and UI logging happen concurrently.
    static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        appendUnlocked(line)
    }

    /// The retained log, including trailing newlines, for the on-screen view.
    static func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked()
    }

    /// Copies the live log to a temporary text file for the share sheet.
    /// The live file stays so sharing does not clear the screen.
    static func makeShareFile() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(shareFileName)
        try Data(readUnlocked().utf8).write(to: destination, options: .atomic)
        return destination
    }

    /// Runs body against a throwaway file so tests can assert retention
    /// without writing the simulator's real log or racing other tests.
    static func isolate<T>(
        directory: URL,
        maxBytes: Int,
        _ body: () throws -> T
    ) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let previousDirectory = directoryOverride
        let previousMax = maxBytesOverride
        directoryOverride = directory
        maxBytesOverride = maxBytes
        defer {
            directoryOverride = previousDirectory
            maxBytesOverride = previousMax
        }
        return try body()
    }

    /// Writes the line and drops oldest whole lines once the file is past
    /// the cap. Failures are ignored so logging cannot take down the
    /// operation that was being recorded.
    private static func appendUnlocked(_ line: String) {
        let url = fileURLUnlocked()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Data((line + "\n").utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try trimUnlocked(url)
        } catch {
            return
        }
    }

    private static func readUnlocked() -> String {
        guard let data = try? Data(contentsOf: fileURLUnlocked()) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fileURLUnlocked() -> URL {
        let directory = directoryOverride ?? applicationSupportDirectory()
        return directory.appendingPathComponent(shareFileName)
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    }

    private static var maxBytes: Int {
        maxBytesOverride ?? maxRetainedBytes
    }

    /// Drops a leading partial line so the retained bytes are the newest
    /// complete lines that still fit in the cap.
    private static func trimUnlocked(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > maxBytes else { return }
        let bytes = [UInt8](data)
        var index = bytes.count - maxBytes
        if bytes[index - 1] != 0x0A {
            guard let newline = bytes[index...].firstIndex(of: 0x0A) else {
                try Data().write(to: url, options: .atomic)
                return
            }
            index = newline + 1
        }
        try Data(bytes[index...]).write(to: url, options: .atomic)
    }
}
