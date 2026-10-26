import Foundation
import Testing
@testable import GitDB
@testable import LibGit2
@testable import iosapp

// The in-app log is what someone shares after the debugger is gone, so
// these tests pin the lines that must survive and the file the share
// sheet attaches.
@Suite("Application Log Tests", .serialized)
struct ApplicationLogTests {
    // Each logger formats its own line. The retained file has to contain
    // those lines in call order, or a shared log would drop git or
    // identity failures that never go through the app logger.
    @Test func loggersAppendInOrder() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let previousSink = diagnosticLogSink
        diagnosticLogSink = { ApplicationLog.append($0) }
        defer { diagnosticLogSink = previousSink }

        try ApplicationLog.isolate(directory: directory, maxBytes: 8 * 1024 * 1024) {
            iosapp.log("from-app-log", context: "ApplicationLog", level: .info)
            LibGit2.log("from-libgit2-log", context: "LibGit2")
            GitDB.log("from-gitdb-log")
            GitDB.logWarning("from-gitdb-warning")
            GitDB.logError("from-gitdb-error")
            GitDB.logDebug("from-gitdb-debug")

            let text = ApplicationLog.text()
            let app = try #require(text.range(of: "[INFO][ApplicationLog] from-app-log"))
            let git = try #require(text.range(of: "[INFO][LibGit2] from-libgit2-log"))
            let db = try #require(text.range(of: "[GitDB] from-gitdb-log"))
            let warning = try #require(text.range(of: "[GitDB] WARNING: from-gitdb-warning"))
            let error = try #require(text.range(of: "[GitDB] ERROR: from-gitdb-error"))
            let debug = try #require(text.range(of: "[GitDB] DEBUG: from-gitdb-debug"))
            #expect(app.lowerBound < git.lowerBound)
            #expect(git.lowerBound < db.lowerBound)
            #expect(db.lowerBound < warning.lowerBound)
            #expect(warning.lowerBound < error.lowerBound)
            #expect(error.lowerBound < debug.lowerBound)
        }
    }

    // Debug lines are already hidden from the system log at the default
    // minimum. They must stay out of the shareable file too, or a share
    // would include chatter the rest of the app deliberately drops.
    @Test func debugLinesBelowTheMinimumAreDropped() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        let previousLevel = iosapp.logMinLevel
        iosapp.logMinLevel = .info
        defer { iosapp.logMinLevel = previousLevel }

        ApplicationLog.isolate(directory: directory, maxBytes: 8 * 1024 * 1024) {
            iosapp.log("debug-should-drop", context: "ApplicationLog", level: .debug)
            iosapp.log("info-should-keep", context: "ApplicationLog", level: .info)
            let text = ApplicationLog.text()
            #expect(!text.contains("debug-should-drop"))
            #expect(text.contains("[INFO][ApplicationLog] info-should-keep"))
        }
    }

    // A long-lived library would otherwise grow the attachment without
    // bound. The file keeps the newest whole lines and stays inside the cap.
    @Test func retentionKeepsNewestWholeLinesWithinTheCap() throws {
        let boundary = try makeDirectory()
        defer { remove(boundary) }
        ApplicationLog.isolate(directory: boundary, maxBytes: 20) {
            for marker in ["111111111", "222222222", "333333333", "444444444", "555555555"] {
                ApplicationLog.append(marker)
            }
            let text = ApplicationLog.text()
            #expect(text.utf8.count <= 20)
            #expect(text == "444444444\n555555555\n")
        }

        let midLine = try makeDirectory()
        defer { remove(midLine) }
        ApplicationLog.isolate(directory: midLine, maxBytes: 25) {
            for marker in ["111111111", "222222222", "333333333", "444444444", "555555555"] {
                ApplicationLog.append(marker)
            }
            let text = ApplicationLog.text()
            #expect(text.utf8.count <= 25)
            #expect(text == "444444444\n555555555\n")
            #expect(!text.contains("333333333"))
        }
    }

    // Mail and Files attach a file URL. A string activity item would paste
    // the log with no name, so the helper has to hand back replycant-log.txt
    // whose bytes match what the screen shows, without deleting the live log.
    @Test func shareFileMatchesTheRetainedLog() throws {
        let directory = try makeDirectory()
        defer { remove(directory) }
        try ApplicationLog.isolate(directory: directory, maxBytes: 8 * 1024 * 1024) {
            ApplicationLog.append("share-me")
            let retained = ApplicationLog.text()
            let url = try ApplicationLog.makeShareFile()
            defer { remove(url) }
            #expect(url.lastPathComponent == "replycant-log.txt")
            let shared = try String(contentsOf: url, encoding: .utf8)
            #expect(shared == retained)
            #expect(shared == "share-me\n")
            try FileManager.default.removeItem(at: url)
            #expect(ApplicationLog.text() == retained)
        }
    }

    // Gives each test its own directory so a cap or share assertion cannot
    // see another test's lines.
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("application-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
