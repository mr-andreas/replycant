import Foundation
import Testing
@testable import iosapp

// Sets up a reusable repository fixture for manifest persistence tests.
@MainActor
func setupManifestTestEnvironment() throws -> (repoPath: String, lfsServer: MockLFSServer, fixtures: TestFixtures) {
    let fixtures = TestFixtures()
    let result = try fixtures.setupTestRepository()
    return (result.repoPath, result.lfsServer, fixtures)
}

// Cleans up fixture repository state created by setupManifestTestEnvironment.
@MainActor
func cleanupManifestTestEnvironment(at path: String, fixtures: TestFixtures) {
    fixtures.cleanupTestRepository(at: path)
}

// Test date helpers
extension Date {
    static func testDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar.current.date(from: components) ?? Date()
    }
}

// String extension for ISO8601 parsing
extension String {
    func toISO8601Date() -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: self)
    }
}

// Data extension for test image creation
extension Data {
    static func testImageData(width: Int, height: Int, color: UInt8 = 100) -> Data {
        let pixelCount = width * height * 3 // RGB
        var data = Data(count: pixelCount)
        
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            for i in 0..<pixelCount {
                ptr[i] = color
            }
        }
        
        return data
    }
}

// Helper to create test manifest YAML
func createTestManifestYAML(
    kind: String,
    name: String,
    deviceSpace: String = "test-device",
    sha256: String = "abc123def456",
    additionalSpec: String = ""
) -> String {
    return """
    apiVersion: media.replycant.com/v1alpha1
    kind: \(kind)
    metadata:
      name: \(name)
      deviceSpace: \(deviceSpace)
    spec:
      id: \(name)
      sha256: \(sha256)
      \(additionalSpec)
    status: {}
    """
}

// Helper to create test LFS pointer
func createTestLFSPointer(oid: String, size: Int) -> String {
    return """
    version https://git-lfs.github.com/spec/v1
    oid sha256:\(oid)
    size \(size)
    """
}

// Test assertion helpers
func assertFileExists(at path: String, file: StaticString = #file, line: UInt = #line) throws {
    guard FileManager.default.fileExists(atPath: path) else {
        Issue.record("File does not exist at path: \(path)", sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 0))
        throw TestError.fileNotFound(path)
    }
}

func assertFileContains(at path: String, substring: String, file: StaticString = #file, line: UInt = #line) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    guard content.contains(substring) else {
        Issue.record("File at \(path) does not contain expected substring: \(substring)", sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 0))
        throw TestError.contentMismatch
    }
}

enum TestError: Error {
    case fileNotFound(String)
    case contentMismatch
    case setupFailed
}

