import Foundation
import CryptoKit

// Centralizes AES-256-GCM operations so manifest encryption and binary chunk
// encryption stay consistent across flows, including position-authenticated LFS framing.
public enum EncryptionUtils {
    // Captures encryption/decryption errors that must abort sync to prevent silent data corruption.
    public enum Error: Swift.Error {
        case invalidKeyLength
        case invalidCiphertext
        case invalidChunkSize
        case invalidKekEpoch
    }

    // Repo-wide plaintext chunk size shared with Go/webapp/decryptd (64 KiB).
    public static let chunkSize = 65_536
    // Per-chunk wire overhead is the GCM tag only; nonces are derived and not stored.
    public static let chunkOverhead = 16
    private static let chunkAADPrefix = Data("replycant-lfs-chunk-v1".utf8)
    private static let dekWrapAADPrefix = Data("replycant-dek-wrap-v1".utf8)

    // Encrypts payloads with random nonces to protect manifest and wrapped-key confidentiality at rest.
    public static func encryptAESGCM(plaintext: Data, key: Data, authenticatedData: Data? = nil) throws -> Data {
        let symmetric = try symmetricKey(from: key)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: symmetric, nonce: nonce, authenticating: authenticatedData ?? Data())
        guard let combined = sealed.combined else {
            throw Error.invalidCiphertext
        }
        return combined
    }

    // Decrypts AES-GCM payloads encoded in combined form so encrypted repository entries can be restored to plaintext.
    public static func decryptAESGCM(ciphertext: Data, key: Data, authenticatedData: Data? = nil) throws -> Data {
        let symmetric = try symmetricKey(from: key)
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: symmetric, authenticating: authenticatedData ?? Data())
    }

    // Wraps a per-object DEK using the current KEK, binding the seal to kek-epoch so
    // pointer metadata cannot be moved across epochs without detection.
    public static func wrapDEK(_ dek: Data, withKEK kek: Data, kekEpoch: Int) throws -> Data {
        try encryptAESGCM(plaintext: dek, key: kek, authenticatedData: dekWrapAAD(kekEpoch: kekEpoch))
    }

    // Unwraps a per-object DEK from pointer metadata so the client can decrypt LFS binary chunks.
    public static func unwrapDEK(_ wrappedDEK: Data, withKEK kek: Data, kekEpoch: Int) throws -> Data {
        try decryptAESGCM(ciphertext: wrappedDEK, key: kek, authenticatedData: dekWrapAAD(kekEpoch: kekEpoch))
    }

    // Encrypts each plaintext chunk with index-derived nonce and AAD so reorder and
    // trailing truncation fail authentication, while preserving random-access reads.
    public static func encryptChunkedBinary(plaintext: Data, dek: Data) throws -> Data {
        if plaintext.isEmpty {
            return Data()
        }
        let symmetric = try symmetricKey(from: dek)
        let totalChunks = (plaintext.count + chunkSize - 1) / chunkSize
        var output = Data()
        output.reserveCapacity(plaintext.count + totalChunks * chunkOverhead)

        for chunkIndex in 0..<totalChunks {
            let offset = chunkIndex * chunkSize
            let end = min(offset + chunkSize, plaintext.count)
            let chunk = plaintext.subdata(in: offset..<end)
            let nonce = try nonceForChunk(index: chunkIndex)
            let aad = try chunkAAD(index: chunkIndex, isLast: chunkIndex == totalChunks - 1)
            let sealed = try AES.GCM.seal(chunk, using: symmetric, nonce: nonce, authenticating: aad)
            output.append(sealed.ciphertext)
            output.append(sealed.tag)
        }

        return output
    }

    // Streams one file through plaintext and encrypted hashers so upload dedup and
    // LFS OID metadata are derived without full-buffer allocations.
    public static func computeStreamingHashes(
        fileURL: URL,
        dek: Data
    ) throws -> (plaintextSHA256: String, encryptedOID: String, encryptedSize: Int64, plaintextSize: Int64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let plaintextSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if plaintextSize == 0 {
            let empty = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
            return (empty, empty, 0, 0)
        }

        let totalChunks = Int((plaintextSize + Int64(chunkSize) - 1) / Int64(chunkSize))
        let symmetric = try symmetricKey(from: dek)
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var plaintextHasher = SHA256()
        var encryptedHasher = SHA256()
        var encryptedSize: Int64 = 0

        for chunkIndex in 0..<totalChunks {
            let chunk = try autoreleasepool {
                if #available(iOS 13.4, macOS 10.15.4, *) {
                    return try fileHandle.read(upToCount: chunkSize) ?? Data()
                }
                return fileHandle.readData(ofLength: chunkSize)
            }
            guard !chunk.isEmpty else {
                throw Error.invalidCiphertext
            }

            plaintextHasher.update(data: chunk)

            let nonce = try nonceForChunk(index: chunkIndex)
            let aad = try chunkAAD(index: chunkIndex, isLast: chunkIndex == totalChunks - 1)
            let sealed = try AES.GCM.seal(chunk, using: symmetric, nonce: nonce, authenticating: aad)

            encryptedHasher.update(data: sealed.ciphertext)
            encryptedHasher.update(data: sealed.tag)
            encryptedSize += Int64(chunk.count + chunkOverhead)
        }

        let plaintextSHA256 = plaintextHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let encryptedOID = encryptedHasher.finalize().map { String(format: "%02x", $0) }.joined()

        return (plaintextSHA256, encryptedOID, encryptedSize, plaintextSize)
    }

    // Decrypts chunked binary payloads produced by encryptChunkedBinary using
    // index-derived nonces and AAD so reorder/truncation fail authentication.
    public static func decryptChunkedBinary(ciphertext: Data, dek: Data) throws -> Data {
        if ciphertext.isEmpty {
            return Data()
        }
        let symmetric = try symmetricKey(from: dek)
        let fullEncryptedChunkSize = chunkSize + chunkOverhead

        var output = Data()
        output.reserveCapacity(max(ciphertext.count - chunkOverhead, 0))

        var offset = 0
        var chunkIndex = 0
        while offset < ciphertext.count {
            let remaining = ciphertext.count - offset
            let currentChunkSize = min(remaining, fullEncryptedChunkSize)
            guard currentChunkSize >= chunkOverhead else {
                throw Error.invalidCiphertext
            }

            let isLast = offset + currentChunkSize == ciphertext.count
            let tagRange = (offset + currentChunkSize - 16)..<(offset + currentChunkSize)
            let cipherRange = offset..<(offset + currentChunkSize - 16)

            let tag = ciphertext.subdata(in: tagRange)
            let encryptedChunk = ciphertext.subdata(in: cipherRange)
            let nonce = try nonceForChunk(index: chunkIndex)
            let aad = try chunkAAD(index: chunkIndex, isLast: isLast)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encryptedChunk, tag: tag)
            let plaintextChunk = try AES.GCM.open(box, using: symmetric, authenticating: aad)
            output.append(plaintextChunk)

            offset += currentChunkSize
            chunkIndex += 1
        }

        return output
    }

    // Builds deterministic per-chunk nonces to guarantee uniqueness for each chunk under a per-object DEK.
    public static func nonceForChunk(index: Int) throws -> AES.GCM.Nonce {
        var bytes = Data(repeating: 0, count: 12)
        let value = UInt64(index).bigEndian
        withUnsafeBytes(of: value) { rawBuffer in
            bytes.replaceSubrange(4..<12, with: rawBuffer)
        }
        return try AES.GCM.Nonce(data: bytes)
    }

    // Binds each seal to its index and last-chunk status so reorder and trailing truncation fail authentication.
    public static func chunkAAD(index: Int, isLast: Bool) throws -> Data {
        guard index >= 0 else {
            throw Error.invalidChunkSize
        }
        var aad = Data()
        aad.append(chunkAADPrefix)
        var value = UInt64(index).bigEndian
        withUnsafeBytes(of: &value) { rawBuffer in
            aad.append(contentsOf: rawBuffer)
        }
        aad.append(isLast ? 1 : 0)
        return aad
    }

    // Binds a wrapped DEK to its kek-epoch so pointer metadata cannot move across epochs.
    public static func dekWrapAAD(kekEpoch: Int) throws -> Data {
        guard kekEpoch >= 1 else {
            throw Error.invalidKekEpoch
        }
        var aad = Data()
        aad.append(dekWrapAADPrefix)
        var value = UInt64(kekEpoch).bigEndian
        withUnsafeBytes(of: &value) { rawBuffer in
            aad.append(contentsOf: rawBuffer)
        }
        return aad
    }

    // Generates random symmetric keys for KEKs/DEKs to enforce independent per-epoch and per-object encryption domains.
    public static func randomKey(length: Int = 32) -> Data {
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, length, buffer.baseAddress!)
        }
        return data
    }

    // Converts raw bytes into a CryptoKit symmetric key while enforcing AES-256 key length.
    private static func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else {
            throw Error.invalidKeyLength
        }
        return SymmetricKey(data: data)
    }
}
