import Foundation
import CryptoKit

#if DEBUG
// Simple HTTP server for serving LFS data during UI tests
// This exists so UITests can fetch deterministic fixture media in-process.
// The listener binds an OS-assigned TCP port without interface restriction.
class TestLFSServer {
    private var storage: [String: Data] = [:]
    private var hlsPlaylists: [String: String] = [:] // Maps OID to HLS playlist content
    private var listener: NWListener?
    private(set) var actualPort: UInt16 = 0
    
    static let shared = TestLFSServer()
    
    private init() {}
    
    // Start the server on an OS-assigned random port and wait until it's ready.
    // Blocks until the server is listening or fails, preventing race conditions
    // where tests try to connect before the server is ready.
    func start() throws {
        let processInfo = ProcessInfo.processInfo
        let isUITesting = processInfo.arguments.contains("--uitesting")
        let isUnitTesting = processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard isUITesting || isUnitTesting else {
            print("TestLFSServer: Not in UI test mode, skipping")
            return
        }
        
        print("TestLFSServer: Starting mock LFS server on random port...")
        
        // Use NWListener for simple HTTP server
        let port = NWEndpoint.Port(integerLiteral: 0)
        listener = try NWListener(using: .tcp, on: port)
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        // Semaphore to block until server is ready or fails
        let readySemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else {
                    readySemaphore.signal()
                    return
                }
                let assignedPort = self.listener?.port?.rawValue ?? 0
                if assignedPort == 0 {
                    startError = NSError(
                        domain: "TestLFSServer",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Server ready without an assigned port"]
                    )
                }
                self.actualPort = assignedPort
                print("TestLFSServer: Server ready on port \(self.actualPort)")
                readySemaphore.signal()
            case .failed(let error):
                print("TestLFSServer: Server failed: \(error)")
                startError = error
                readySemaphore.signal()
            case .cancelled:
                print("TestLFSServer: Server cancelled")
            default:
                break
            }
        }
        
        // Runs above utility priority so listener readiness is not starved
        // behind lower-priority work while many test suites execute in
        // parallel on a loaded CI machine.
        listener?.start(queue: .global(qos: .userInitiated))
        
        // Wait for server to be ready. The budget is generous because a
        // contended CI runner can take far longer to bind than a developer
        // machine, and a spurious timeout here fails otherwise-passing tests.
        let timeout = DispatchTime.now() + .seconds(30)
        if readySemaphore.wait(timeout: timeout) == .timedOut {
            throw NSError(domain: "TestLFSServer", code: -1, 
                         userInfo: [NSLocalizedDescriptionKey: "Server start timed out"])
        }
        
        if let error = startError {
            throw error
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        actualPort = 0
        print("TestLFSServer: Stopping server, clearing \(storage.count) storage items and \(hlsPlaylists.count) playlists")
        storage.removeAll()
        hlsPlaylists.removeAll()
    }
    
    // Debug method to list all registered playlists
    func listRegisteredPlaylists() {
        print("TestLFSServer: Currently registered playlists (\(hlsPlaylists.count)):")
        for (oid, _) in hlsPlaylists {
            print("TestLFSServer:   - OID: \(oid)")
        }
    }
    
    // Store data by OID
    func store(oid: String, data: Data) {
        storage[oid] = data
    }
    
    // Register HLS playlist for an OID
    func registerHLSPlaylist(oid: String, playlistContent: String) {
        hlsPlaylists[oid] = playlistContent
        print("TestLFSServer: Registered HLS playlist for OID: \(oid)")
        print("TestLFSServer: Total registered playlists: \(hlsPlaylists.count)")
        print("TestLFSServer: Registered OIDs: \(hlsPlaylists.keys.joined(separator: ", "))")
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receiveRequest(on: connection, buffer: Data())
    }
    
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let error {
                print("TestLFSServer: Connection receive error: \(error)")
                connection.cancel()
                return
            }

            var updatedBuffer = buffer
            if let data, !data.isEmpty {
                updatedBuffer.append(data)
            }
            
            if self.isCompleteHTTPRequest(updatedBuffer) {
                self.processRequest(data: updatedBuffer, connection: connection)
                return
            }

            if isComplete {
                self.send400(connection: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: updatedBuffer)
        }
    }

    // Determines whether one full HTTP request (headers + optional body) is buffered.
    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            return false
        }

        let headerBytes = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headers = String(data: headerBytes, encoding: .utf8) else {
            return false
        }

        let contentLength = parseContentLength(from: headers) ?? 0
        let bodyStart = headerRange.upperBound
        let availableBodyLength = data.count - bodyStart
        return availableBodyLength >= contentLength
    }

    // Parses Content-Length from HTTP header block when present.
    private func parseContentLength(from headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            let lowercased = line.lowercased()
            guard lowercased.hasPrefix("content-length:") else {
                continue
            }
            let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }
    
    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8),
              let requestLine = requestString.components(separatedBy: "\r\n").first,
              requestLine.components(separatedBy: " ").count >= 2 else {
            send400(connection: connection)
            return
        }
        
        let path = requestLine.components(separatedBy: " ")[1]
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        
        if normalizedPath.hasPrefix("hls/") {
            handleHLSRequest(path: normalizedPath, connection: connection)
        } else if path.contains("/objects/batch") || path.contains("/lfs/objects/batch") {
            handleBatchRequest(data: data, connection: connection)
        } else if path.contains("/objects/") {
            let components = path.components(separatedBy: "/")
            if let objectsIndex = components.lastIndex(of: "objects"),
               objectsIndex + 1 < components.count {
                handleDownload(
                    oid: components[objectsIndex + 1],
                    requestString: requestString,
                    connection: connection
                )
            } else {
                send404(connection: connection)
            }
        } else {
            send404(connection: connection)
        }
    }
    
    private func handleBatchRequest(data: Data, connection: NWConnection) {
        // Find JSON body in HTTP request
        guard let requestString = String(data: data, encoding: .utf8) else {
            send400(connection: connection)
            return
        }
        
        // Extract JSON from HTTP body
        let components = requestString.components(separatedBy: "\r\n\r\n")
        guard components.count >= 2,
              let jsonData = components[1].data(using: .utf8) else {
            send400(connection: connection)
            return
        }
        
        do {
            let request = try JSONDecoder().decode(BatchRequest.self, from: jsonData)
            let response = processBatchRequest(request)
            let responseData = try JSONEncoder().encode(response)
            
            sendJSONResponse(data: responseData, connection: connection)
        } catch {
            print("TestLFSServer: Batch request error: \(error)")
            send400(connection: connection)
        }
    }
    
    private func processBatchRequest(_ request: BatchRequest) -> BatchResponse {
        var objects: [BatchResponseObject] = []
        
        for obj in request.objects {
            if let _ = storage[obj.oid] {
                // Object exists, provide download URL
                objects.append(BatchResponseObject(
                    oid: obj.oid,
                    size: obj.size,
                    authenticated: true,
                    actions: BatchActions(
                        download: DownloadAction(
                            href: "http://localhost:\(actualPort)/lfs/objects/\(obj.oid)"
                        ),
                        upload: nil
                    ),
                    error: nil
                ))
            } else {
                // Object not found
                print("TestLFSServer: OID not found in storage: \(obj.oid)")
                objects.append(BatchResponseObject(
                    oid: obj.oid,
                    size: obj.size,
                    authenticated: true,
                    actions: nil,
                    error: ErrorInfo(
                        code: 404,
                        message: "Object not found"
                    )
                ))
            }
        }
        
        return BatchResponse(
            transfer: "basic",
            objects: objects
        )
    }
    
    private func handleHLSRequest(path: String, connection: NWConnection) {
        let components = path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard components.count >= 4, components[0] == "hls" else {
            send404(connection: connection)
            return
        }
        
        let oid = components[1]
        let filename = components.last ?? ""
        
        if filename == "playlist.m3u8" {
            var playlist = hlsPlaylists[oid]
            if playlist == nil, storage[oid] != nil {
                playlist = TestSupport.generateHLSPlaylist(oid: oid, duration: 10.0, resolution: "640x360")
                hlsPlaylists[oid] = playlist
            }
            
            guard let playlist = playlist else {
                send404(connection: connection)
                return
            }
            
            let playlistData = playlist.data(using: .utf8)!
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(playlistData.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            let response = header.data(using: .utf8)! + playlistData
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else if filename == "segment.mp4" {
            guard let data = storage[oid] else {
                send404(connection: connection)
                return
            }
            
            let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            let response = header.data(using: .utf8)! + data
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            send404(connection: connection)
        }
    }
    
    // Streams object bytes for both Git LFS and direct-play test routes.
    private func handleDownload(oid: String, requestString: String, connection: NWConnection) {
        guard let data = storage[oid] else {
            send404(connection: connection)
            return
        }
        if let byteRange = parseByteRange(from: requestString, totalLength: data.count) {
            sendPartialBinaryResponse(data: data, range: byteRange, connection: connection)
            return
        }
        sendBinaryResponse(data: data, connection: connection)
    }
    
    private func sendJSONResponse(data: Data, connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.git-lfs+json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        let headerData = header.data(using: .utf8)!
        let fullResponse = headerData + data
        
        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    
    // Returns full object bytes when playback does not request a byte range.
    private func sendBinaryResponse(data: Data, connection: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        let headerData = header.data(using: .utf8)!
        let fullResponse = headerData + data
        
        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // Returns a byte-range slice so AVPlayer can seek while streaming direct-play objects.
    private func sendPartialBinaryResponse(data: Data, range: ClosedRange<Int>, connection: NWConnection) {
        let clampedLower = max(0, range.lowerBound)
        let clampedUpper = min(data.count - 1, range.upperBound)
        guard clampedLower <= clampedUpper else {
            send400(connection: connection)
            return
        }

        let payload = data.subdata(in: clampedLower..<(clampedUpper + 1))
        let header = """
        HTTP/1.1 206 Partial Content\r
        Content-Type: application/octet-stream\r
        Content-Length: \(payload.count)\r
        Content-Range: bytes \(clampedLower)-\(clampedUpper)/\(data.count)\r
        Accept-Ranges: bytes\r
        Connection: close\r
        \r
        """
        let headerData = header.data(using: String.Encoding.utf8)!
        let fullResponse = headerData + payload
        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // Parses an RFC 7233 byte range so direct-play requests can fetch partial content.
    private func parseByteRange(from requestString: String, totalLength: Int) -> ClosedRange<Int>? {
        guard totalLength > 0 else { return nil }
        let lines = requestString.components(separatedBy: "\r\n")
        guard let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }) else {
            return nil
        }
        let rangeValue = rangeLine.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
        guard rangeValue.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = rangeValue.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let startText = String(parts[0])
        let endText = String(parts[1])
        if let start = Int(startText) {
            let end = Int(endText) ?? (totalLength - 1)
            return start...end
        }

        guard let suffixLength = Int(endText), suffixLength > 0 else {
            return nil
        }
        let lowerBound = max(totalLength - suffixLength, 0)
        return lowerBound...(totalLength - 1)
    }
    
    private func send404(connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
    
    private func send400(connection: NWConnection) {
        let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

// LFS API structures
private struct BatchRequest: Codable {
    let operation: String
    let transfers: [String]?
    let objects: [LFSObject]
    
    struct LFSObject: Codable {
        let oid: String
        let size: Int64
    }
}

private struct BatchResponse: Codable {
    let transfer: String
    let objects: [BatchResponseObject]
}

private struct BatchResponseObject: Codable {
    let oid: String
    let size: Int64
    let authenticated: Bool?
    let actions: BatchActions?
    let error: ErrorInfo?
}

private struct BatchActions: Codable {
    let download: DownloadAction?
    let upload: UploadAction?
}

private struct DownloadAction: Codable {
    let href: String
    let header: [String: String]?
    let expires_at: String?
    
    init(href: String, header: [String: String]? = nil, expires_at: String? = nil) {
        self.href = href
        self.header = header
        self.expires_at = expires_at
    }
}

private struct UploadAction: Codable {
    let href: String
    let header: [String: String]?
    let expires_at: String?
}

private struct ErrorInfo: Codable {
    let code: Int
    let message: String
}

// Import Network framework
import Network

#endif
