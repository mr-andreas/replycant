import Foundation
import Security

/// Answers URLSession authentication challenges for the single mTLS endpoint
/// this app trusts.
///
/// gitd fronts every backend service (Git, LFS, decryptd, transcoded) behind
/// one mutually authenticated endpoint, so every URLSession that talks to the
/// server needs identical challenge handling: present the device identity, and
/// pin the server chain to the CA captured during onboarding. This type exists
/// so that logic lives in one place rather than being reimplemented by each
/// client (LFS transfers, direct playback, HLS playback).
///
/// Both credentials are optional so test clients and pre-onboarding code paths
/// can run without an identity. When no identity is available the class rejects
/// the protection space rather than falling back to an unauthenticated request,
/// which keeps failures loud instead of silently unauthenticated.
public class MTLSURLSessionAuthDelegate: NSObject, URLSessionDelegate {
    private let clientIdentity: SecIdentity?
    private let pinnedCA: SecCertificate?

    public init(clientIdentity: SecIdentity?, pinnedCA: SecCertificate?) {
        self.clientIdentity = clientIdentity
        self.pinnedCA = pinnedCA
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            handleServerTrust(challenge, completionHandler: completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            handleClientCertificate(completionHandler: completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // Pins the server trust chain to the onboarded CA when available.
    private func handleServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let pinnedCA else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if verifyCertificateChain(serverTrust: serverTrust, pinnedCA: pinnedCA) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // Provides a configured client certificate when the server requests mTLS authentication.
    private func handleClientCertificate(
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let clientIdentity else {
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        completionHandler(
            .useCredential,
            URLCredential(identity: clientIdentity, certificates: nil, persistence: .forSession)
        )
    }

    // Confirms the pinned CA is trusted for the presented chain, including short/self-issued chains.
    private func verifyCertificateChain(serverTrust: SecTrust, pinnedCA: SecCertificate) -> Bool {
        guard let chainArray = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            return false
        }

        let pinnedCAData = SecCertificateCopyData(pinnedCA) as Data
        for cert in chainArray {
            let certData = SecCertificateCopyData(cert) as Data
            if certData == pinnedCAData {
                return true
            }
        }

        guard let leafCert = chainArray.first else {
            return false
        }
        return verifyLeafCert(leafCert: leafCert, pinnedCA: pinnedCA)
    }

    // Re-evaluates trust with the pinned CA anchor when the chain omits the full issuer set.
    private func verifyLeafCert(leafCert: SecCertificate, pinnedCA: SecCertificate) -> Bool {
        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates([leafCert, pinnedCA] as CFArray, policy, &trust)
        guard status == errSecSuccess, let trust else {
            return false
        }

        SecTrustSetAnchorCertificates(trust, [pinnedCA] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
