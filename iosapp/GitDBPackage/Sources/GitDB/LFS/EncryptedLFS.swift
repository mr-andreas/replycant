import Foundation
import CryptoKit
import LibGit2

// Names encryption-pointer failures so GitDB can reject plaintext
// or malformed LFS metadata without LibGit2 knowing replycant fields.
public enum EncryptedLFSError: Error {
    case invalidEncryptionMetadata
    case invalidFileURL
    case fileReadError(String)
}

// Carries replycant LFS pointer metadata so git commits store
// kek-epoch and wrapped-DEK beside the vanilla oid/size lines.
public struct EncryptedLFSPointer {
    public let oid: String
    public let size: Int64
    public let kekEpoch: Int
    public let wrappedDEK: String

    public init(oid: String, size: Int64, kekEpoch: Int, wrappedDEK: String) {
        self.oid = oid
        self.size = size
        self.kekEpoch = kekEpoch
        self.wrappedDEK = wrappedDEK
    }

    // Renders the on-disk pointer so encrypted objects stay
    // discoverable by vanilla LFS while carrying wrap metadata.
    public var content: String {
        [
            "version https://git-lfs.github.com/spec/v1",
            "oid sha256:\(oid)",
            "size \(size)",
            "x-replycant-kek-epoch \(kekEpoch)",
            "x-replycant-wrapped-dek \(wrappedDEK)"
        ].joined(separator: "\n")
    }

    // Parses one pointer so decrypt paths share a single
    // x-replycant field reader instead of per-call-site copies.
    public static func parse(_ pointerContent: String) throws -> EncryptedLFSPointer {
        let lines = pointerContent.components(separatedBy: .newlines)
        var oid: String?
        var size: Int64?
        var kekEpoch: Int?
        var wrappedDEK: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("oid sha256:") {
                oid = String(trimmed.dropFirst("oid sha256:".count))
            } else if trimmed.hasPrefix("size ") {
                size = Int64(trimmed.dropFirst("size ".count))
            } else if trimmed.hasPrefix("x-replycant-kek-epoch ") {
                kekEpoch = Int(trimmed.dropFirst("x-replycant-kek-epoch ".count))
            } else if trimmed.hasPrefix("x-replycant-wrapped-dek ") {
                wrappedDEK = String(trimmed.dropFirst("x-replycant-wrapped-dek ".count))
            }
        }

        guard let oid,
              oid.count == 64,
              let size,
              let kekEpoch,
              let wrappedDEK,
              !wrappedDEK.isEmpty else {
            throw EncryptedLFSError.invalidEncryptionMetadata
        }

        return EncryptedLFSPointer(
            oid: oid,
            size: size,
            kekEpoch: kekEpoch,
            wrappedDEK: wrappedDEK
        )
    }
}

// Wraps LibGit2 LFS transport with replycant encrypt/decrypt so
// callers never ask vanilla git to interpret wrapped DEKs.
public enum EncryptedLFS {
    // Uploads one source file while encrypting each chunk into the
    // PUT body so large originals never stage full ciphertext.
    @available(iOS 13.0, macOS 10.15, *)
    public static func uploadEncrypted(
        fileURL: URL,
        dek: Data,
        oid: String,
        size: Int64,
        lfsClient: GitLFS,
        progressHandler: ((Int64, Int64) -> Void)? = nil
    ) async throws -> LFSPointer {
        try await lfsClient.uploadStream(
            oid: oid,
            size: size,
            progressHandler: progressHandler
        ) {
            try EncryptingInputStream(fileURL: fileURL, dek: dek)
        }
    }

    // Reads one encrypted pointer, downloads opaque LFS bytes, and
    // unwraps the DEK locally so KEK material never leaves the device.
    @available(iOS 13.0, macOS 10.15, *)
    public static func loadEncryptedLFSData(
        from filePath: String,
        repository: Repository,
        lfsClient: GitLFS
    ) async throws -> Data {
        let pointerContent = try repository.readFile(at: filePath)
        let pointer = try EncryptedLFSPointer.parse(pointerContent)
        let downloaded = try await lfsClient.downloadData(oid: pointer.oid, size: pointer.size)
        let kek = try KEKEpochManager(repository: repository).loadKEK(epoch: pointer.kekEpoch)
        guard let wrappedDEKData = Data(base64Encoded: pointer.wrappedDEK) else {
            throw EncryptedLFSError.invalidEncryptionMetadata
        }
        let dek = try EncryptionUtils.unwrapDEK(
            wrappedDEKData,
            withKEK: kek,
            kekEpoch: pointer.kekEpoch
        )
        return try EncryptionUtils.decryptChunkedBinary(ciphertext: downloaded, dek: dek)
    }
}

// Streams encrypted chunks from a source file so URLSession can
// upload ciphertext without buffering whole objects in memory.
final class EncryptingInputStream: InputStream {
    private let fileURL: URL
    private let symmetricKey: SymmetricKey
    private let totalChunks: Int
    private var fileHandle: FileHandle?
    private var chunkIndex = 0
    private var encryptedBuffer = Data()
    private var encryptedBufferOffset = 0
    private var currentStatus: Stream.Status = .notOpen
    private var currentError: Swift.Error?
    private weak var _delegate: (any StreamDelegate)?

    // Initializes deterministic chunk encryption state for one
    // upload request body. totalChunks is derived from file size
    // so the last-chunk AAD flag is known before reading.
    init(fileURL: URL, dek: Data) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw EncryptedLFSError.invalidFileURL
        }
        guard dek.count == 32 else {
            throw EncryptedLFSError.invalidEncryptionMetadata
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let plaintextSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let totalChunks = plaintextSize == 0
            ? 0
            : Int((plaintextSize + Int64(EncryptionUtils.chunkSize) - 1)
                / Int64(EncryptionUtils.chunkSize))

        self.fileURL = fileURL
        self.symmetricKey = SymmetricKey(data: dek)
        self.totalChunks = totalChunks
        super.init(data: Data())
    }

    override var delegate: (any StreamDelegate)? {
        get { _delegate }
        set { _delegate = newValue }
    }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override var hasBytesAvailable: Bool {
        switch currentStatus {
        case .open:
            return true
        case .atEnd:
            return false
        default:
            return false
        }
    }

    override var streamStatus: Stream.Status {
        currentStatus
    }

    override var streamError: Swift.Error? {
        currentError
    }

    override func open() {
        guard currentStatus == .notOpen else { return }
        do {
            fileHandle = try FileHandle(forReadingFrom: fileURL)
            chunkIndex = 0
            encryptedBuffer.removeAll(keepingCapacity: true)
            encryptedBufferOffset = 0
            currentStatus = .open
        } catch {
            currentError = error
            currentStatus = .error
        }
    }

    override func close() {
        try? fileHandle?.close()
        fileHandle = nil
        encryptedBuffer.removeAll(keepingCapacity: false)
        encryptedBufferOffset = 0
        currentStatus = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard currentStatus == .open else {
            return currentStatus == .atEnd ? 0 : -1
        }
        guard len > 0 else { return 0 }

        if encryptedBufferOffset >= encryptedBuffer.count {
            do {
                let didLoadChunk = try loadNextEncryptedChunk()
                if !didLoadChunk {
                    currentStatus = .atEnd
                    return 0
                }
            } catch {
                currentError = error
                currentStatus = .error
                return -1
            }
        }

        let available = encryptedBuffer.count - encryptedBufferOffset
        let toCopy = min(available, len)
        guard toCopy > 0 else {
            currentStatus = .atEnd
            return 0
        }

        encryptedBuffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(buffer, baseAddress.advanced(by: encryptedBufferOffset), toCopy)
        }
        encryptedBufferOffset += toCopy

        if encryptedBufferOffset >= encryptedBuffer.count {
            encryptedBuffer.removeAll(keepingCapacity: true)
            encryptedBufferOffset = 0
        }

        return toCopy
    }

    // Encrypts one plaintext chunk and stages ciphertext||tag
    // bytes for subsequent stream reads.
    private func loadNextEncryptedChunk() throws -> Bool {
        guard let fileHandle else {
            throw EncryptedLFSError.fileReadError("File handle is not open")
        }
        guard chunkIndex < totalChunks else {
            return false
        }

        let plaintextChunk: Data
        if #available(iOS 13.4, macOS 10.15.4, *) {
            plaintextChunk = try fileHandle.read(upToCount: EncryptionUtils.chunkSize) ?? Data()
        } else {
            plaintextChunk = fileHandle.readData(ofLength: EncryptionUtils.chunkSize)
        }

        if plaintextChunk.isEmpty {
            throw EncryptedLFSError.fileReadError(
                "Unexpected early EOF while encrypting chunk \(chunkIndex)"
            )
        }

        let nonce = try EncryptionUtils.nonceForChunk(index: chunkIndex)
        let aad = try EncryptionUtils.chunkAAD(
            index: chunkIndex,
            isLast: chunkIndex == totalChunks - 1
        )
        let sealed = try AES.GCM.seal(
            plaintextChunk,
            using: symmetricKey,
            nonce: nonce,
            authenticating: aad
        )
        encryptedBuffer.removeAll(keepingCapacity: true)
        encryptedBuffer.append(sealed.ciphertext)
        encryptedBuffer.append(sealed.tag)
        encryptedBufferOffset = 0
        chunkIndex += 1
        return true
    }
}
