import Foundation
import Testing
import LibGit2
@testable import GitDB

// Guards the LibGit2/GitDB LFS boundary so vanilla pointers never
// grow replycant fields and encrypted pointers stay parseable.
struct EncryptedLFSPointerTests {
    private static let oid = String(repeating: "a", count: 64)
    private static let encryptedOID = String(repeating: "b", count: 64)

    // Pins LibGit2's pointer renderer to the three git-lfs spec lines
    // so x-replycant metadata cannot leak back into the vanilla type.
    @Test func libgit2PointerRendersOnlySpecLines() {
        let pointer = LFSPointer(oid: Self.oid, size: 10)
        #expect(pointer.content == """
        version https://git-lfs.github.com/spec/v1
        oid sha256:\(Self.oid)
        size 10
        """)
        #expect(!pointer.content.contains("x-replycant-"))
    }

    // Ensures GitDB's encrypted pointer is the single render/parse
    // path for kek-epoch and wrapped-dek metadata.
    @Test func encryptedPointerRoundTripsRenderThenParse() throws {
        let original = EncryptedLFSPointer(
            oid: Self.encryptedOID,
            size: 42,
            kekEpoch: 2,
            wrappedDEK: "d3JhcHBlZA=="
        )
        let parsed = try EncryptedLFSPointer.parse(original.content)
        #expect(parsed.oid == original.oid)
        #expect(parsed.size == original.size)
        #expect(parsed.kekEpoch == original.kekEpoch)
        #expect(parsed.wrappedDEK == original.wrappedDEK)
        #expect(original.content.contains("x-replycant-kek-epoch 2"))
        #expect(original.content.contains("x-replycant-wrapped-dek d3JhcHBlZA=="))
        #expect(!original.content.contains("x-replycant-chunk-size"))
    }
}
