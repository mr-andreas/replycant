import Foundation
import Security
import CryptoKit

// Manages ECDSA P-256 client identity for mTLS authentication with gitd server.
// Uses P-256 because iOS Security framework only supports RSA/ECDSA for SecIdentity,
// not Ed25519, which is required for URLSession client certificate authentication.
final class ClientIdentityManager {
    
    // Singleton instance for app-wide identity management.
    static let shared = ClientIdentityManager()
    
    private let privateKeyTag = "com.replycant.iosapp.p256.private"
    private let certificateLabel = "com.replycant.iosapp.p256.certificate"
    private let agePrivateKeyTag = "com.replycant.iosapp.age.private"
    private let recoveryPrivateKeyTag = "com.replycant.iosapp.recovery.p256.private"
    private let recoveryCertificateLabel = "com.replycant.iosapp.recovery.p256.certificate"
    
    private init() {}
    
    // MARK: - Public Interface
    
    // Checks if a client identity already exists in the Keychain.
    func hasIdentity() -> Bool {
        return loadSecKey() != nil && loadSecCertificate() != nil
    }
    
    // Ensures both mTLS identity and age encryption identity exist while preserving immutable P-256 behavior.
    func generateIdentityIfNeeded(commonName: String) throws {
        // Check if mTLS identity already exists.
        if !hasIdentity() {
            log("Generating new P-256 identity for '\(commonName)' (first time setup)", context: "ClientIdentity")

            // Generate P-256 private key directly in Keychain.
            let privateKey = try generatePrivateKey()

            // Get the public key.
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw IdentityError.certificateCreationFailed
            }

            // Create self-signed certificate.
            let certificateDER = try createSelfSignedCertificate(
                privateKey: privateKey,
                publicKey: publicKey,
                commonName: commonName
            )

            // Store certificate in Keychain, linked to the private key.
            try storeCertificate(certificateDER, privateKey: privateKey, certificateLabel: certificateLabel)
            log("Successfully generated and stored P-256 identity", context: "ClientIdentity")
        } else {
            log("P-256 identity already exists, skipping generation", context: "ClientIdentity")
        }

        // Ensure age identity exists for repository content encryption.
        if loadAgePrivateKey() == nil {
            try generateAgePrivateKey()
            log("Successfully generated and stored age identity", context: "ClientIdentity")
        } else {
            log("age identity already exists, skipping generation", context: "ClientIdentity")
        }
    }

    // Imports an optional local simulator identity when present so debug builds can skip QR onboarding.
    // Credentials are never shipped in-repo; developers place them under SimulatorCredentials/ locally.
    func importBundledSimulatorIdentityIfNeeded() throws {
        #if DEBUG && targetEnvironment(simulator)
        guard let certificatePEM = loadBundledCredential(named: "device", ext: "crt"),
              let privateKeyPEM = loadBundledCredential(named: "device", ext: "key"),
              let identityJSON = loadBundledCredential(named: "identity", ext: "json") else {
            log("No local simulator credentials bundled; skipping identity import", context: "ClientIdentity")
            return
        }

        let bundledDER = try decodeCertificateDER(fromPEM: certificatePEM)
        if !isCurrentCertificateMatching(bundledDER: bundledDER) {
            try deleteIdentityForSimulatorOverride()
        }
        try importIdentity(certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM)
        try importBundledAgePrivateKey(fromIdentityJSON: identityJSON)
        log("Loaded bundled simulator identity from PEM resources", context: "ClientIdentity")
        #endif
    }

    // Clears mTLS and age identity material so integration tests can force deterministic first-run onboarding.
    func resetIdentityForTesting() throws {
        #if DEBUG
        try deleteIdentityForSimulatorOverride()
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: agePrivateKeyTag
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw IdentityError.keychainError(deleteStatus)
        }
        #endif
    }
    
    // Returns the SSH-format public key for committing to pubkeys/ directory.
    // Format: "ecdsa-sha2-nistp256 AAAA... comment"
    func sshPublicKey(comment: String = "") throws -> String {
        guard let privateKey = loadSecKey(),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw IdentityError.noIdentity
        }
        
        return try formatSSHPublicKey(publicKey: publicKey, comment: comment)
    }

    // Returns the Bech32 age public key so onboarding and linking can exchange encryption recipients.
    func agePublicKey() throws -> String {
        guard let privateKey = loadAgePrivateKey() else {
            throw IdentityError.noAgeIdentity
        }
        return try Bech32.encode(hrp: "age", data: privateKey.publicKey.rawRepresentation)
    }

    // Loads the Curve25519 age private key used to decrypt KEK epoch files locally.
    func agePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let privateKey = loadAgePrivateKey() else {
            throw IdentityError.noAgeIdentity
        }
        return privateKey
    }
    
    // Loads the SecIdentity for use in URLSession authentication challenges.
    func loadSecIdentity() -> SecIdentity? {
        loadSecIdentity(certificateLabel: certificateLabel, privateKeyTag: privateKeyTag)
    }

    // Builds a throwaway identity used only during recovery so the device identity remains immutable.
    func makeTemporaryIdentity(privateKeyPEM: String, commonName: String) throws -> SecIdentity {
        try deleteTemporaryIdentity()
        let importedPrivateKey = try importPrivateKeyIfNeeded(fromPEM: privateKeyPEM, keyTag: recoveryPrivateKeyTag)
        guard let importedPublicKey = SecKeyCopyPublicKey(importedPrivateKey) else {
            throw IdentityError.certificateCreationFailed
        }
        let certificateDER = try createSelfSignedCertificate(
            privateKey: importedPrivateKey,
            publicKey: importedPublicKey,
            commonName: commonName
        )
        try storeCertificate(certificateDER, privateKey: importedPrivateKey, certificateLabel: recoveryCertificateLabel)
        guard let identity = loadSecIdentity(certificateLabel: recoveryCertificateLabel, privateKeyTag: recoveryPrivateKeyTag) else {
            throw IdentityError.noIdentity
        }
        return identity
    }

    // Removes temporary recovery identity artifacts so follow-up network operations use the device identity only.
    func deleteTemporaryIdentity() throws {
        try deleteIdentity(keyTag: recoveryPrivateKeyTag, certificateLabel: recoveryCertificateLabel)
    }

    // Loads a Keychain identity by explicit labels so primary and temporary identities can coexist.
    private func loadSecIdentity(certificateLabel: String, privateKeyTag: String) -> SecIdentity? {
        // Query for identity by finding certificate with matching private key
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certificateLabel,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        if status == errSecSuccess, let identity = item {
            logDebug("Loaded SecIdentity from Keychain", context: "ClientIdentity")
            return (identity as! SecIdentity)
        }
        
        // Fallback: try to match by private key tag
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: privateKeyTag.data(using: .utf8)!,
            kSecReturnRef as String: true
        ]
        
        var keyItem: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyItem)
        
        if keyStatus == errSecSuccess, let identity = keyItem {
            logDebug("Loaded SecIdentity via key tag", context: "ClientIdentity")
            return (identity as! SecIdentity)
        }

        logError("Failed to load SecIdentity: \(status)", context: "ClientIdentity")
        return nil
    }
    
    // Returns the DER-encoded certificate data.
    func loadCertificate() throws -> Data {
        guard let cert = loadSecCertificate() else {
            throw IdentityError.noIdentity
        }
        return SecCertificateCopyData(cert) as Data
    }
    
    // MARK: - Private Key Operations
    
    // Generates a P-256 private key directly in the Keychain.
    private func generatePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: privateKeyTag.data(using: .utf8)!,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        
        var error: Unmanaged<CFError>?
        
        // Try Secure Enclave first
        if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) {
            log("Created P-256 key in Secure Enclave", context: "ClientIdentity")
            return key
        }
        
        // Fall back to regular Keychain (simulator doesn't have Secure Enclave)
        var softwareAttributes = attributes
        softwareAttributes.removeValue(forKey: kSecAttrTokenID as String)
        
        error = nil
        guard let key = SecKeyCreateRandomKey(softwareAttributes as CFDictionary, &error) else {
            logError("Failed to create private key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")", context: "ClientIdentity")
            throw IdentityError.keychainError(-1)
        }
        
        log("Created P-256 key in Keychain", context: "ClientIdentity")
        return key
    }

    // Generates and persists a Curve25519 age private key so the device can unwrap KEKs for encrypted content.
    private func generateAgePrivateKey() throws {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let privateKeyData = privateKey.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: agePrivateKeyTag,
            kSecValueData as String: privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw IdentityError.keychainError(status)
        }
    }
    
    private func loadSecKey(tag: String? = nil) -> SecKey? {
        let resolvedTag = tag ?? privateKeyTag
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: resolvedTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            return nil
        }
        
        return (item as! SecKey)
    }

    // Loads the stored Curve25519 age private key so KEK epochs can be decrypted without regenerating identity material.
    private func loadAgePrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: agePrivateKeyTag,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return privateKey
    }

    // Imports PEM credentials into Keychain so simulator startup can authenticate without key generation.
    private func importIdentity(certificatePEM: String, privateKeyPEM: String) throws {
        let importedPrivateKey = try importPrivateKeyIfNeeded(fromPEM: privateKeyPEM, keyTag: privateKeyTag)
        let certificateDER = try decodeCertificateDER(fromPEM: certificatePEM)
        try storeCertificate(certificateDER, privateKey: importedPrivateKey, certificateLabel: certificateLabel)
    }

    // Converts a bundled PEM certificate into DER needed by Security.framework APIs.
    private func decodeCertificateDER(fromPEM pem: String) throws -> Data {
        let lines = pem.components(separatedBy: .newlines)
        let base64 = lines
            .filter { !$0.contains("BEGIN CERTIFICATE") && !$0.contains("END CERTIFICATE") }
            .joined()
        guard let derData = Data(base64Encoded: base64) else {
            throw IdentityError.certificateCreationFailed
        }
        return derData
    }

    // Imports the bundled EC private key only when no key exists, preserving idempotent startup behavior.
    private func importPrivateKeyIfNeeded(fromPEM pem: String, keyTag: String) throws -> SecKey {
        if let existingKey = loadSecKey(tag: keyTag) {
            return existingKey
        }

        let createAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]

        var candidateKeyData: [Data] = []

        if let parsed = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            candidateKeyData.append(parsed.x963Representation)
        }
        if let rawFromSEC1 = try? extractRawP256PrivateKey(fromECPem: pem) {
            candidateKeyData.append(rawFromSEC1)
        }
        if let der = decodePrivateKeyDER(fromPEM: pem) {
            candidateKeyData.append(der)
        }

        guard !candidateKeyData.isEmpty else {
            throw IdentityError.certificateCreationFailed
        }

        var secKey: SecKey?
        for keyData in candidateKeyData {
            var createError: Unmanaged<CFError>?
            if let created = SecKeyCreateWithData(keyData as CFData, createAttributes as CFDictionary, &createError) {
                secKey = created
                break
            }
        }

        guard let secKey else {
            throw IdentityError.certificateCreationFailed
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueRef as String: secKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IdentityError.keychainError(addStatus)
        }

        guard let storedKey = loadSecKey(tag: keyTag) else {
            throw IdentityError.noIdentity
        }
        return storedKey
    }

    // Decodes PEM private key content so import can try both DER and raw scalar representations.
    private func decodePrivateKeyDER(fromPEM pem: String) -> Data? {
        let lines = pem.components(separatedBy: .newlines)
        let base64 = lines
            .filter { !$0.contains("BEGIN EC PRIVATE KEY") && !$0.contains("END EC PRIVATE KEY") && !$0.contains("BEGIN PRIVATE KEY") && !$0.contains("END PRIVATE KEY") }
            .joined()
        return Data(base64Encoded: base64)
    }

    // Extracts the 32-byte P-256 private scalar from SEC1 EC PRIVATE KEY PEM for simulator credential import.
    private func extractRawP256PrivateKey(fromECPem pem: String) throws -> Data {
        let lines = pem.components(separatedBy: .newlines)
        let base64 = lines
            .filter { !$0.contains("BEGIN EC PRIVATE KEY") && !$0.contains("END EC PRIVATE KEY") }
            .joined()
        guard let der = Data(base64Encoded: base64) else {
            throw IdentityError.certificateCreationFailed
        }

        var index = 0

        func readByte() throws -> UInt8 {
            guard index < der.count else { throw IdentityError.certificateCreationFailed }
            defer { index += 1 }
            return der[index]
        }

        func readLength() throws -> Int {
            let first = try readByte()
            if first & 0x80 == 0 {
                return Int(first)
            }

            let byteCount = Int(first & 0x7F)
            guard byteCount > 0 && byteCount <= 4 else {
                throw IdentityError.certificateCreationFailed
            }

            var length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(try readByte())
            }
            return length
        }

        func skipTLV(tag expectedTag: UInt8) throws {
            let tag = try readByte()
            guard tag == expectedTag else { throw IdentityError.certificateCreationFailed }
            let length = try readLength()
            guard index + length <= der.count else { throw IdentityError.certificateCreationFailed }
            index += length
        }

        // SEQUENCE
        let sequenceTag = try readByte()
        guard sequenceTag == 0x30 else { throw IdentityError.certificateCreationFailed }
        _ = try readLength()

        // INTEGER version
        try skipTLV(tag: 0x02)

        // OCTET STRING private key
        let octetTag = try readByte()
        guard octetTag == 0x04 else { throw IdentityError.certificateCreationFailed }
        let keyLength = try readLength()
        guard keyLength == 32, index + keyLength <= der.count else {
            throw IdentityError.certificateCreationFailed
        }

        let keyData = der.subdata(in: index..<(index + keyLength))
        return keyData
    }

    // Reads optional local simulator credential resources from the app bundle when present.
    private func loadBundledCredential(named name: String, ext: String) -> String? {
        let subdirectories: [String?] = ["SimulatorCredentials", "Resources/SimulatorCredentials", nil]

        for subdirectory in subdirectories {
            let resourceURL: URL?
            if let subdirectory {
                resourceURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            } else {
                resourceURL = Bundle.main.url(forResource: name, withExtension: ext)
            }

            if let resourceURL,
               let content = try? String(contentsOf: resourceURL, encoding: .utf8) {
                return content
            }
        }

        return nil
    }

    // Ensures simulator debug sessions can detect whether an existing identity is compatible with local test server auth.
    private func isCurrentCertificateMatching(bundledDER: Data) -> Bool {
        guard let currentCertificate = loadSecCertificate() else {
            return false
        }
        let currentDER = SecCertificateCopyData(currentCertificate) as Data
        return currentDER == bundledDER
    }

    // Clears existing identity artifacts so simulator bootstrap can replace stale credentials that cause 401 responses.
    private func deleteIdentityForSimulatorOverride() throws {
        try deleteIdentity(keyTag: privateKeyTag, certificateLabel: certificateLabel)
    }

    // Removes one identity pair selected by key tag and certificate label.
    private func deleteIdentity(keyTag: String, certificateLabel: String) throws {
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        let keyDeleteStatus = SecItemDelete(keyQuery as CFDictionary)
        if keyDeleteStatus != errSecSuccess && keyDeleteStatus != errSecItemNotFound {
            throw IdentityError.keychainError(keyDeleteStatus)
        }

        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certificateLabel
        ]
        let certDeleteStatus = SecItemDelete(certQuery as CFDictionary)
        if certDeleteStatus != errSecSuccess && certDeleteStatus != errSecItemNotFound {
            throw IdentityError.keychainError(certDeleteStatus)
        }
    }

    // Decodes bundled simulator metadata and stores the deterministic age private key used by local encryption tests.
    private func importBundledAgePrivateKey(fromIdentityJSON jsonString: String) throws {
        struct SimulatorBundledIdentityMetadata: Decodable {
            let agePrivateKeyBase64: String
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let metadata = try? JSONDecoder().decode(SimulatorBundledIdentityMetadata.self, from: jsonData),
              let privateKeyData = Data(base64Encoded: metadata.agePrivateKeyBase64) else {
            throw IdentityError.certificateCreationFailed
        }

        if let existing = loadAgePrivateKey(), existing.rawRepresentation == privateKeyData {
            return
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: agePrivateKeyTag
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            throw IdentityError.keychainError(deleteStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: agePrivateKeyTag,
            kSecValueData as String: privateKeyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw IdentityError.keychainError(addStatus)
        }
    }
    
    // MARK: - Certificate Storage
    
    private func storeCertificate(_ certificateDER: Data, privateKey: SecKey, certificateLabel: String) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            logError("Failed to create SecCertificate from DER", context: "ClientIdentity")
            throw IdentityError.certificateCreationFailed
        }
        
        // Store certificate in Keychain with label for retrieval
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certificateLabel,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            logError("Failed to store certificate: \(status)", context: "ClientIdentity")
            throw IdentityError.keychainError(status)
        }
        
        log("Stored certificate in Keychain", context: "ClientIdentity")
    }
    
    private func loadSecCertificate(label: String? = nil) -> SecCertificate? {
        let resolvedLabel = label ?? certificateLabel
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: resolvedLabel,
            kSecReturnRef as String: true
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            return nil
        }
        
        return (item as! SecCertificate)
    }
    
    // MARK: - X.509 Certificate Creation
    
    // Creates a self-signed X.509 v3 certificate with ECDSA-SHA256 signature.
    private func createSelfSignedCertificate(
        privateKey: SecKey,
        publicKey: SecKey,
        commonName: String
    ) throws -> Data {
        
        // Export public key to get raw bytes
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.certificateCreationFailed
        }
        
        // Build TBSCertificate
        let tbsCertificate = buildTBSCertificate(
            publicKeyData: publicKeyData,
            commonName: commonName
        )
        
        // Sign using SecKeyCreateSignature
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw IdentityError.certificateCreationFailed
        }
        
        error = nil
        guard let signature = SecKeyCreateSignature(
            privateKey,
            algorithm,
            tbsCertificate as CFData,
            &error
        ) as Data? else {
            logError("Signing failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown")", context: "ClientIdentity")
            throw IdentityError.certificateCreationFailed
        }
        
        // Build complete certificate
        let certificate = buildCertificate(
            tbsCertificate: tbsCertificate,
            signature: signature
        )
        
        log("Created self-signed X.509 certificate (\(certificate.count) bytes)", context: "ClientIdentity")
        return certificate
    }
    
    private func buildTBSCertificate(publicKeyData: Data, commonName: String) -> Data {
        var tbs = Data()
        
        // Version: v3 (2)
        tbs.append(DER.contextTag(0, contents: DER.integer(2)))
        
        // Serial number (random)
        var serialBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &serialBytes)
        serialBytes[0] &= 0x7F // Ensure positive
        tbs.append(DER.integer(Data(serialBytes)))
        
        // Signature algorithm: ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
        tbs.append(DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])]))
        
        // Issuer (same as subject for self-signed)
        let issuerName = buildName(commonName: commonName)
        tbs.append(issuerName)
        
        // Validity (10 years from now)
        tbs.append(buildValidity())
        
        // Subject
        tbs.append(issuerName)
        
        // Subject Public Key Info for P-256
        tbs.append(buildSubjectPublicKeyInfo(publicKeyData: publicKeyData))
        
        return DER.sequence(tbs)
    }
    
    private func buildName(commonName: String) -> Data {
        let cnOID = DER.oid([2, 5, 4, 3]) // id-at-commonName
        let cnValue = DER.utf8String(commonName)
        let atv = DER.sequence([cnOID, cnValue])
        let rdn = DER.set([atv])
        return DER.sequence([rdn])
    }
    
    private func buildValidity() -> Data {
        let now = Date()
        let tenYearsLater = Calendar.current.date(byAdding: .year, value: 10, to: now)!
        
        return DER.sequence([
            DER.utcTime(now),
            DER.utcTime(tenYearsLater)
        ])
    }
    
    private func buildSubjectPublicKeyInfo(publicKeyData: Data) -> Data {
        // Algorithm: id-ecPublicKey (1.2.840.10045.2.1) with prime256v1 (1.2.840.10045.3.1.7)
        let algorithm = DER.sequence([
            DER.oid([1, 2, 840, 10045, 2, 1]),
            DER.oid([1, 2, 840, 10045, 3, 1, 7])
        ])
        
        // Public key is already in X9.62 uncompressed format (04 || x || y)
        let publicKeyBits = DER.bitString(publicKeyData)
        
        return DER.sequence([algorithm, publicKeyBits])
    }
    
    private func buildCertificate(tbsCertificate: Data, signature: Data) -> Data {
        // Signature algorithm: ecdsa-with-SHA256
        let signatureAlgorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        
        // Signature value as bit string
        let signatureValue = DER.bitString(signature)
        
        return DER.sequence([tbsCertificate, signatureAlgorithm, signatureValue])
    }
    
    // MARK: - SSH Public Key Format
    
    private func formatSSHPublicKey(publicKey: SecKey, comment: String) throws -> String {
        // Export public key
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.noIdentity
        }
        
        // SSH ecdsa-sha2-nistp256 format:
        // string "ecdsa-sha2-nistp256"
        // string "nistp256"
        // string Q (uncompressed point)
        
        var keyData = Data()
        
        let keyType = "ecdsa-sha2-nistp256"
        let curveName = "nistp256"
        
        // Add key type
        let keyTypeData = keyType.data(using: .utf8)!
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(keyTypeData.count).bigEndian) { Array($0) })
        keyData.append(keyTypeData)
        
        // Add curve name
        let curveData = curveName.data(using: .utf8)!
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(curveData.count).bigEndian) { Array($0) })
        keyData.append(curveData)
        
        // Add public key point (already in uncompressed format with 04 prefix)
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(publicKeyData.count).bigEndian) { Array($0) })
        keyData.append(publicKeyData)
        
        let base64Key = keyData.base64EncodedString()
        
        if comment.isEmpty {
            return "ecdsa-sha2-nistp256 \(base64Key)"
        } else {
            return "ecdsa-sha2-nistp256 \(base64Key) \(comment)"
        }
    }
}

// Errors that can occur during identity operations.
enum IdentityError: Error, LocalizedError {
    case noIdentity
    case noAgeIdentity
    case keychainError(OSStatus)
    case certificateCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .noIdentity:
            return "No client identity found"
        case .noAgeIdentity:
            return "No age identity found"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .certificateCreationFailed:
            return "Failed to create X.509 certificate"
        }
    }
}

// MARK: - DER Encoding Helpers

// Minimal DER encoder for X.509 certificate construction.
private enum DER {
    
    static func sequence(_ contents: Data) -> Data {
        return tag(0x30, contents: contents)
    }
    
    static func sequence(_ items: [Data]) -> Data {
        var contents = Data()
        for item in items {
            contents.append(item)
        }
        return sequence(contents)
    }
    
    static func set(_ items: [Data]) -> Data {
        var contents = Data()
        for item in items {
            contents.append(item)
        }
        return tag(0x31, contents: contents)
    }
    
    static func integer(_ value: Int) -> Data {
        var bytes = [UInt8]()
        var v = value
        
        if v == 0 {
            bytes = [0]
        } else {
            while v > 0 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            if bytes[0] & 0x80 != 0 {
                bytes.insert(0, at: 0)
            }
        }
        
        return tag(0x02, contents: Data(bytes))
    }
    
    static func integer(_ data: Data) -> Data {
        var bytes = Array(data)
        if !bytes.isEmpty && bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tag(0x02, contents: Data(bytes))
    }
    
    static func bitString(_ data: Data) -> Data {
        var contents = Data([0x00])
        contents.append(data)
        return tag(0x03, contents: contents)
    }
    
    static func octetString(_ data: Data) -> Data {
        return tag(0x04, contents: data)
    }
    
    static func oid(_ components: [Int]) -> Data {
        var bytes = Data()
        
        if components.count >= 2 {
            bytes.append(UInt8(components[0] * 40 + components[1]))
        }
        
        for i in 2..<components.count {
            bytes.append(contentsOf: encodeBase128(components[i]))
        }
        
        return tag(0x06, contents: bytes)
    }
    
    static func utf8String(_ string: String) -> Data {
        let data = string.data(using: .utf8) ?? Data()
        return tag(0x0C, contents: data)
    }
    
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateString = formatter.string(from: date) + "Z"
        let data = dateString.data(using: .ascii) ?? Data()
        return tag(0x17, contents: data)
    }
    
    static func contextTag(_ number: Int, contents: Data) -> Data {
        let tagByte = UInt8(0xA0 | (number & 0x1F))
        return tagWithByte(tagByte, contents: contents)
    }
    
    private static func tag(_ tagByte: UInt8, contents: Data) -> Data {
        return tagWithByte(tagByte, contents: contents)
    }
    
    private static func tagWithByte(_ tagByte: UInt8, contents: Data) -> Data {
        var result = Data([tagByte])
        result.append(encodeLength(contents.count))
        result.append(contents)
        return result
    }
    
    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else {
            var bytes = [UInt8]()
            var len = length
            while len > 0 {
                bytes.insert(UInt8(len & 0xFF), at: 0)
                len >>= 8
            }
            bytes.insert(UInt8(0x80 | bytes.count), at: 0)
            return Data(bytes)
        }
    }
    
    private static func encodeBase128(_ value: Int) -> [UInt8] {
        if value == 0 {
            return [0]
        }
        
        var bytes = [UInt8]()
        var v = value
        
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        }
        
        for i in 0..<(bytes.count - 1) {
            bytes[i] |= 0x80
        }
        
        return bytes
    }
}
