import Foundation
import CryptoKit
import Testing
import LibGit2
@testable import iosapp

// Verifies position-authenticated LFS chunk framing so Swift stays aligned with
// Go and TypeScript on nonce derivation, AAD, overhead, and golden ciphertext.
struct ChunkFramingTests {
    private static let goldenDEK = Data(repeating: 0x11, count: 32)
    private static let goldenCiphertextSHA256 =
        "a8300613749c6d09bb332763ed5ea3c547aee4f86d85b374483fb9c2af38e053"

    private static var goldenPlaintext: Data {
        var data = Data(repeating: 0x42, count: EncryptionUtils.chunkSize)
        data.append(contentsOf: "tail-7!".utf8)
        return data
    }

    // Pins the repo-wide constant chosen after seek/throughput measurement.
    @Test func chunkSizeIs64KiB() {
        #expect(EncryptionUtils.chunkSize == 65_536)
        #expect(EncryptionUtils.chunkOverhead == 16)
    }

    // Keeps nonce layout aligned with Go/webapp ChunkNonce helpers.
    @Test func nonceForChunkMatchesZeroPrefixedBigEndianIndex() throws {
        let nonce0 = try EncryptionUtils.nonceForChunk(index: 0)
        #expect(Data(nonce0) == Data(repeating: 0, count: 12))

        let nonce1 = try EncryptionUtils.nonceForChunk(index: 1)
        var expected = Data(repeating: 0, count: 12)
        var value = UInt64(1).bigEndian
        withUnsafeBytes(of: &value) { rawBuffer in
            expected.replaceSubrange(4..<12, with: rawBuffer)
        }
        #expect(Data(nonce1) == expected)
    }

    // Verifies AAD layout so reorder/truncation changes fail authentication.
    @Test func chunkAADBindsIndexAndLastFlag() throws {
        let last = try EncryptionUtils.chunkAAD(index: 2, isLast: true)
        let notLast = try EncryptionUtils.chunkAAD(index: 2, isLast: false)
        #expect(String(data: last.prefix("replycant-lfs-chunk-v1".count), encoding: .utf8) == "replycant-lfs-chunk-v1")
        #expect(last.last == 1)
        #expect(notLast.last == 0)
        #expect(last != notLast)
    }

    // Verifies v2 framing roundtrips and uses 16-byte per-chunk overhead.
    @Test func encryptChunkedRoundtripUsesSixteenByteOverhead() throws {
        let dek = Data(repeating: 0x03, count: 32)
        let plaintext = Data(repeating: UInt8(ascii: "p"), count: 90_000)
        let encrypted = try EncryptionUtils.encryptChunkedBinary(plaintext: plaintext, dek: dek)
        let n = (plaintext.count + EncryptionUtils.chunkSize - 1) / EncryptionUtils.chunkSize
        #expect(encrypted.count == plaintext.count + n * EncryptionUtils.chunkOverhead)
        let roundtrip = try EncryptionUtils.decryptChunkedBinary(ciphertext: encrypted, dek: dek)
        #expect(roundtrip == plaintext)
    }

    // Keeps empty objects free of a spurious authenticated frame.
    @Test func emptyPlaintextProducesZeroChunks() throws {
        let dek = Data(repeating: 0x03, count: 32)
        let encrypted = try EncryptionUtils.encryptChunkedBinary(plaintext: Data(), dek: dek)
        #expect(encrypted.isEmpty)
        let roundtrip = try EncryptionUtils.decryptChunkedBinary(ciphertext: encrypted, dek: dek)
        #expect(roundtrip.isEmpty)
    }

    // Ensures swapping frames fails because index-derived nonces and AAD bind position.
    @Test func decryptRejectsReorderedChunks() throws {
        let encrypted = try EncryptionUtils.encryptChunkedBinary(
            plaintext: Self.goldenPlaintext,
            dek: Self.goldenDEK
        )
        let frame0 = EncryptionUtils.chunkSize + EncryptionUtils.chunkOverhead
        var swapped = Data(encrypted.suffix(from: frame0))
        swapped.append(encrypted.prefix(frame0))
        #expect(throws: (any Error).self) {
            _ = try EncryptionUtils.decryptChunkedBinary(ciphertext: swapped, dek: Self.goldenDEK)
        }
    }

    // Ensures trailing truncation fails because the new last frame was sealed with isLast=0.
    @Test func decryptRejectsDroppedLastChunk() throws {
        let encrypted = try EncryptionUtils.encryptChunkedBinary(
            plaintext: Self.goldenPlaintext,
            dek: Self.goldenDEK
        )
        let frame0 = EncryptionUtils.chunkSize + EncryptionUtils.chunkOverhead
        let truncated = encrypted.prefix(frame0)
        #expect(throws: (any Error).self) {
            _ = try EncryptionUtils.decryptChunkedBinary(ciphertext: Data(truncated), dek: Self.goldenDEK)
        }
    }

    // Binds wrapped DEKs to kek-epoch so pointer metadata cannot move across epochs.
    @Test func unwrapDEKRejectsWrongEpoch() throws {
        let kek = Data(repeating: 0x01, count: 32)
        let dek = Data(repeating: 0x02, count: 32)
        let wrapped = try EncryptionUtils.wrapDEK(dek, withKEK: kek, kekEpoch: 3)
        let unwrapped = try EncryptionUtils.unwrapDEK(wrapped, withKEK: kek, kekEpoch: 3)
        #expect(unwrapped == dek)
        #expect(throws: (any Error).self) {
            _ = try EncryptionUtils.unwrapDEK(wrapped, withKEK: kek, kekEpoch: 4)
        }
    }

    // Pins the ciphertext digest shared with Go and TypeScript.
    @Test func goldenCiphertextDigestMatchesCrossPlatformVector() throws {
        let encrypted = try EncryptionUtils.encryptChunkedBinary(
            plaintext: Self.goldenPlaintext,
            dek: Self.goldenDEK
        )
        #expect(encrypted.count == EncryptionUtils.chunkSize + 7 + 2 * EncryptionUtils.chunkOverhead)
        let digest = SHA256.hash(data: encrypted).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.goldenCiphertextSHA256)
    }

    // Chunk size leaves the pointer wire format entirely.
    @Test func lfsPointerOmitsChunkSize() {
        let pointer = LFSPointer(
            oid: String(repeating: "a", count: 64),
            size: 10,
            kekEpoch: 2,
            wrappedDEK: "wrapped"
        )
        #expect(!pointer.content.contains("x-replycant-chunk-size"))
        #expect(pointer.content.contains("x-replycant-kek-epoch 2"))
    }
}
