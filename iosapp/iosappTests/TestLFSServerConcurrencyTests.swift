import Foundation
import CryptoKit
import Testing
import LibGit2
@testable import iosapp

@Suite("TestLFSServer Concurrency Tests", .serialized)
struct TestLFSServerConcurrencyTests {
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func handlesConcurrentBatchAndDownloadRequests() async throws {
        let server = TestLFSServer.shared
        server.stop()
        try server.start()
        defer { server.stop() }

        #expect(server.actualPort > 0)

        var fixtures: [(oid: String, data: Data)] = []
        fixtures.reserveCapacity(16)
        for index in 0..<16 {
            let payload = Data(repeating: UInt8(index), count: 2048 + index * 97)
            let oid = sha256Hex(payload)
            server.store(oid: oid, data: payload)
            fixtures.append((oid: oid, data: payload))
        }

        let serverURL = "http://localhost:\(server.actualPort)/lfs"
        try await withThrowingTaskGroup(of: Void.self) { group in
            for fixture in fixtures {
                group.addTask {
                    let client = GitLFS(serverURL: serverURL)
                    let downloaded = try await client.downloadData(
                        oid: fixture.oid,
                        size: Int64(fixture.data.count)
                    )
                    #expect(downloaded == fixture.data)
                }
            }
            try await group.waitForAll()
        }
    }
}
