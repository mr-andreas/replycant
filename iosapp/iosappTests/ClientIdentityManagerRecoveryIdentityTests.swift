import CryptoKit
import Foundation
import Testing
@testable import iosapp

// Verifies recovery identity import uses separate keychain tags from the device identity.
@MainActor
@Suite(.sharedAppState)
struct ClientIdentityManagerRecoveryIdentityTests {
    // Ensures temporary recovery identity lifecycle never replaces the persistent device identity.
    @Test func temporaryIdentityDoesNotOverrideDeviceIdentity() throws {
        #if DEBUG
        try ClientIdentityManager.shared.generateIdentityIfNeeded(commonName: "primary-device")
        let beforeSSH = try ClientIdentityManager.shared.sshPublicKey(comment: "before")
        let beforeCert = try ClientIdentityManager.shared.loadCertificate()

        let recoveryKey = P256.Signing.PrivateKey()
        let temporary = try ClientIdentityManager.shared.makeTemporaryIdentity(
            privateKeyPEM: recoveryKey.pemRepresentation,
            commonName: "recovery-temporary"
        )
        #expect(temporary as SecIdentity? != nil)

        try ClientIdentityManager.shared.deleteTemporaryIdentity()

        let afterSSH = try ClientIdentityManager.shared.sshPublicKey(comment: "after")
        let afterCert = try ClientIdentityManager.shared.loadCertificate()
        #expect(beforeSSH.replacingOccurrences(of: " before", with: "") == afterSSH.replacingOccurrences(of: " after", with: ""))
        #expect(beforeCert == afterCert)
        #else
        return
        #endif
    }

    // Ensures temp identity cleanup is idempotent so recovery failure paths can always call it safely.
    @Test func temporaryIdentityDeleteIsIdempotent() throws {
        #if DEBUG
        try ClientIdentityManager.shared.deleteTemporaryIdentity()
        try ClientIdentityManager.shared.deleteTemporaryIdentity()
        #else
        return
        #endif
    }
}
