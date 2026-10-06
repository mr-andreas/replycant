import CryptoKit
import Foundation
import GitDB
import LibGit2

/// The device's side of tailnet pairing.
///
/// A new device can reach nothing: it has no CA to
/// trust, no tailnet credential, and no route to gitd. So instead of asking the
/// server for anything, it publishes a pairing secret in its QR code and waits
/// for the operator's device to seal a record under that secret and publish it
/// to the discovery service.
///
/// The steps live here rather than in the view because each one has a distinct
/// failure the user needs told apart - nobody scanned the code, the wrong
/// attempt's record arrived, the CA does not match its hostname - and a view
/// body is the wrong place to keep that straight.
enum TailnetPairing {
    /// Builds the QR the operator scans.
    ///
    /// `pairing_secret` names the slot this device polls for its record. The
    /// field names match `buildPublicKeyQrPayload` in the webapp and
    /// `QRScanValidation` here, since all three have to agree for a scan to
    /// be understood.
    static func deviceQRPayload(
        publicKeySSH: String,
        agePublicKey: String,
        deviceName: String,
        deviceUUID: String,
        pairingSecret: String
    ) throws -> String {
        let fields = [
            "pubkey": publicKeySSH,
            "age_pubkey": agePublicKey,
            "name": deviceName,
            "uuid": deviceUUID,
            "pairing_secret": pairingSecret
        ]

        let data = try JSONSerialization.data(withJSONObject: fields)
        return String(decoding: data, as: UTF8.self)
    }

    /// Waits for the operator to authorize this device, and returns the record
    /// they sealed for it.
    ///
    /// A poll rather than a request because there is nothing to request from:
    /// the device is waiting on a human action on another device, and the slot
    /// is genuinely absent until that happens.
    ///
    /// The CA is checked against the fingerprint carried in the headscale
    /// hostname before it is returned. That check does not depend on the
    /// record's encryption holding, so a record that opened correctly but names
    /// a different CA than the deployment's own is still refused.
    static func awaitAuthorization(
        secretEncoded: String,
        slot: String,
        ageIdentity: Curve25519.KeyAgreement.PrivateKey,
        host: String = DiscoveryClient.defaultHost,
        interval: TimeInterval = DiscoveryClient.defaultInterval,
        timeout: TimeInterval = DiscoveryClient.defaultTimeout,
        session: URLSession = .shared
    ) async throws -> PairingRecord.Payload {
        let sealed = try await DiscoveryClient.pollForRecord(
            slot: slot,
            host: host,
            interval: interval,
            timeout: timeout,
            session: session
        )
        let payload = try PairingRecord.open(
            sealed: sealed,
            secretEncoded: secretEncoded,
            ageIdentity: ageIdentity
        )
        try PairingRecord.verifyCALabel(payload)
        return payload
    }

    /// Acts on an opened record: joins the tailnet, then points the app at gitd.
    ///
    /// Ordered this way because gitd's MagicDNS name does not resolve and its
    /// address is not routable until the node is up, so configuring first would
    /// leave the app holding a URL it cannot use and a sync that fails looking
    /// like the server is down.
    ///
    /// Returns the gitd URL so the caller can clone from it without rederiving
    /// the name.
    @discardableResult
    static func adopt(
        payload: PairingRecord.Payload,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Stored before joining, because the tailnet control plane is
        // authenticated with mTLS against this same CA: the node cannot come up
        // without it being installed first.
        try ServerConfigurationManager.shared.configure(
            url: TailnetConfiguration.gitdURL,
            caCertificate: payload.caPEM
        )

        try await TailnetBootstrap.shared.joinAndPersist(
            payload: payload,
            onProgress: onProgress
        )
        return TailnetConfiguration.gitdURL
    }
}
