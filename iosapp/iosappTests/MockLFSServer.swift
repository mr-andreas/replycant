import Foundation
import CryptoKit

// Mock LFS server for testing
// Implements the Git LFS batch API without requiring network access
class MockLFSServer {
    private var storage: [String: Data] = [:]
    private var requestLog: [LFSRequest] = []
    
    enum LFSRequest {
        case batchUpload(oid: String, size: Int64)
        case batchDownload(oid: String, size: Int64)
        case upload(oid: String, data: Data)
        case download(oid: String)
    }
    
    // Store data by OID
    func store(oid: String, data: Data) {
        storage[oid] = data
    }
    
    // Retrieve data by OID
    func retrieve(oid: String) -> Data? {
        return storage[oid]
    }
    
    // Check if OID exists
    func exists(oid: String) -> Bool {
        return storage[oid] != nil
    }
    
    // Get all stored OIDs
    func allOIDs() -> [String] {
        return Array(storage.keys)
    }
    
    // Clear all stored data
    func clear() {
        storage.removeAll()
        requestLog.removeAll()
    }
    
    // Get request log for testing
    func getRequestLog() -> [LFSRequest] {
        return requestLog
    }
    
    // Mock batch upload request
    func handleBatchUploadRequest(objects: [(oid: String, size: Int64)]) -> BatchResponse {
        var responseObjects: [BatchResponseObject] = []
        
        for obj in objects {
            requestLog.append(.batchUpload(oid: obj.oid, size: obj.size))
            
            if exists(oid: obj.oid) {
                // Object already exists, no upload needed
                responseObjects.append(BatchResponseObject(
                    oid: obj.oid,
                    size: obj.size,
                    actions: nil,
                    error: nil
                ))
            } else {
                // Object needs to be uploaded
                responseObjects.append(BatchResponseObject(
                    oid: obj.oid,
                    size: obj.size,
                    actions: BatchActions(
                        upload: UploadAction(
                            href: "mock://upload/\(obj.oid)",
                            header: [:]
                        ),
                        download: nil
                    ),
                    error: nil
                ))
            }
        }
        
        return BatchResponse(objects: responseObjects)
    }
    
    // Mock batch download request
    func handleBatchDownloadRequest(objects: [(oid: String, size: Int64)]) -> BatchResponse {
        var responseObjects: [BatchResponseObject] = []
        
        for obj in objects {
            requestLog.append(.batchDownload(oid: obj.oid, size: obj.size))
            
            if exists(oid: obj.oid) {
                // Object exists, provide download URL
                responseObjects.append(BatchResponseObject(
                    oid: obj.oid,
                    size: obj.size,
                    actions: BatchActions(
                        upload: nil,
                        download: DownloadAction(
                            href: "mock://download/\(obj.oid)",
                            header: [:]
                        )
                    ),
                    error: nil
                ))
            } else {
                // Object not found
                responseObjects.append(BatchResponseObject(
                    oid: obj.oid,
                    size: obj.size,
                    actions: nil,
                    error: ErrorInfo(
                        code: 404,
                        message: "Object not found"
                    )
                ))
            }
        }
        
        return BatchResponse(objects: responseObjects)
    }
    
    // Mock upload data
    func handleUpload(oid: String, data: Data) -> Bool {
        requestLog.append(.upload(oid: oid, data: data))
        
        // Verify hash matches
        let calculatedHash = Self.calculateSHA256(data: data)
        guard calculatedHash == oid else {
            return false
        }
        
        store(oid: oid, data: data)
        return true
    }
    
    // Mock download data
    func handleDownload(oid: String) -> Data? {
        requestLog.append(.download(oid: oid))
        return retrieve(oid: oid)
    }
    
    // Calculate SHA256 hash
    static func calculateSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    // Response structures matching Git LFS API
    struct BatchResponse: Codable {
        let objects: [BatchResponseObject]
    }
    
    struct BatchResponseObject: Codable {
        let oid: String
        let size: Int64
        let actions: BatchActions?
        let error: ErrorInfo?
    }
    
    struct BatchActions: Codable {
        let upload: UploadAction?
        let download: DownloadAction?
    }
    
    struct UploadAction: Codable {
        let href: String
        let header: [String: String]
    }
    
    struct DownloadAction: Codable {
        let href: String
        let header: [String: String]
    }
    
    struct ErrorInfo: Codable {
        let code: Int
        let message: String
    }
}

// Extension to provide synchronous test helpers
extension MockLFSServer {
    // Upload data and return pointer info
    func uploadData(_ data: Data) -> (oid: String, size: Int64) {
        let oid = Self.calculateSHA256(data: data)
        let size = Int64(data.count)
        store(oid: oid, data: data)
        return (oid, size)
    }
    
    // Download data by OID
    func downloadData(oid: String, size: Int64) throws -> Data {
        guard let data = retrieve(oid: oid) else {
            throw LFSError.notFound
        }
        
        guard Int64(data.count) == size else {
            throw LFSError.sizeMismatch
        }
        
        return data
    }
    
    enum LFSError: Error {
        case notFound
        case sizeMismatch
        case hashMismatch
    }
}


