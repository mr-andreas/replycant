import Foundation
import Testing
@testable import GitDB

// Checks the key set file against the Go writer, and that a sealed
// display name cannot be moved onto another key set.
struct KeySetTests {
    private static let goFixture = """
    apiVersion: gitdb.replycant.com/v1alpha1
    kind: KeySet
    metadata:
      name: iphone-16e
    spec:
      type: device
      mtlsPublicKey: ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHRl+gi7RtSRc6vdZ+Yi9UDbHAjG6AU7bGguZE6PrPipUw+vUZxniQRRaMy/rwuKaIM/KRmDaslS/CpN5+1NvJE= phone
      agePublicKey: age1gffmd3cp4aae4ellqlqladxvtej9za6qsqpyquudjrwj06j4q95qqn5m8a
      displayName:
        kekEpoch: 1
        ciphertext: hft2iHvLZbmAStdGhP/Xs5zvfMhhp5Mk5U3Fd+iXQmO51NLINmtBf4ubIVg=
    """

    @Test func parsesGoYAMLAndRoundTrips() throws {
        let parsed = try KeySet.parse(Self.goFixture)
        #expect(parsed.metadata.name == "iphone-16e")
        #expect(parsed.spec.type == KeySet.typeDevice)
        #expect(parsed.spec.mtlsPublicKey.hasPrefix("ecdsa-sha2-nistp256 "))
        #expect(parsed.spec.displayName?.kekEpoch == 1)
        let again = try KeySet.parse(try parsed.yaml())
        #expect(again == parsed)
        #expect(KeySet.path(name: parsed.metadata.name) == "pubkeys/iphone-16e.yaml")
    }

    @Test func rejectsWrongKindMissingKeyAndUnknownType() throws {
        #expect(throws: KeySetError.self) {
            try KeySet.parse(Self.goFixture.replacingOccurrences(of: "kind: KeySet", with: "kind: Other"))
        }
        #expect(throws: KeySetError.self) {
            try KeySet.parse(Self.goFixture.replacingOccurrences(of: "mtlsPublicKey: ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHRl+gi7RtSRc6vdZ+Yi9UDbHAjG6AU7bGguZE6PrPipUw+vUZxniQRRaMy/rwuKaIM/KRmDaslS/CpN5+1NvJE= phone\n", with: ""))
        }
        #expect(throws: KeySetError.self) {
            try KeySet.parse(Self.goFixture.replacingOccurrences(of: "type: device", with: "type: laptop"))
        }
        let app = try KeySet.parse(Self.goFixture.replacingOccurrences(of: "type: device", with: "type: app"))
        #expect(app.spec.type == KeySet.typeApp)
    }

    @Test func displayNameRoundTripRejectsSwappedName() throws {
        let kek = Data(repeating: 7, count: 32)
        var keySet = try KeySet.parse(Self.goFixture)
        keySet.spec.displayName = try KeySet.encryptDisplayName(
            kek: kek,
            epoch: 2,
            name: keySet.metadata.name,
            plaintext: "Andreas's iPhone"
        )
        #expect(try keySet.decryptDisplayName(kek: kek) == "Andreas's iPhone")

        keySet.metadata.name = "other-phone"
        #expect(throws: KeySetError.invalidDisplayName) {
            try keySet.decryptDisplayName(kek: kek)
        }
        #expect(keySet.resolvedDisplayName(kek: kek) == "other-phone")
    }

    @Test func absentDisplayNameFallsBackToSlug() throws {
        var keySet = try KeySet.parse(Self.goFixture)
        keySet.spec.displayName = nil
        #expect(throws: KeySetError.displayNameAbsent) {
            try keySet.decryptDisplayName(kek: Data(repeating: 1, count: 32))
        }
        #expect(keySet.resolvedDisplayName(kek: Data(repeating: 1, count: 32)) == "iphone-16e")
    }

    @Test func metadataNameKeepsAFilenameSafeSlug() {
        #expect(KeySet.metadataName(from: "André's iPhone") == "andr-s-iphone")
        #expect(KeySet.metadataName(from: "16") == "device-16")
        #expect(KeySet.isValidName(KeySet.metadataName(from: "Kitchen iPad")))
    }
}
