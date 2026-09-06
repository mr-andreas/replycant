import Foundation

/// Reader side of the discovery handshake, mirroring
/// `webapp/src/lib/discovery.ts`.
///
/// A pairing device has nothing to talk to yet, so it cannot be told when its
/// record is ready. It polls its own slot instead, which is derived from the
/// pairing secret in the QR it is displaying and is therefore known only to
/// this device and to whoever scanned it.
///
/// Polling is deliberately plain: the record is opaque and single-use, so a
/// wasted read costs nothing and a missed one just means another attempt.
public enum DiscoveryClient {
    public enum DiscoveryError: LocalizedError, Equatable {
        case unexpectedStatus(Int)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Discovery service returned \(status) while waiting for the pairing record."
            case .timedOut:
                return "Timed out waiting for the server to approve this device. "
                    + "Start pairing again to retry."
            }
        }
    }

    /// Parent domain records are published under. The slot goes in front of
    /// this as a subdomain, so a record's address never appears in a request
    /// path or query where an intermediary could log it.
    public static let defaultHost = "discovery.replycant.com"

    /// gitd publishes as soon as the operator approves the device, which is a
    /// human action, so a tighter interval buys nothing but load.
    public static let defaultInterval: TimeInterval = 2

    /// The record's own TTL is ten minutes, so waiting longer than that could
    /// only ever return nothing.
    public static let defaultTimeout: TimeInterval = 10 * 60

    public static func recordURL(slot: String, host: String = defaultHost) -> URL? {
        URL(string: "https://\(slot).\(host)/")
    }

    /// Waits for the sealed pairing record to appear in a slot.
    ///
    /// Returns the record's raw bytes; the caller decrypts it, because this
    /// layer must never be in a position to read one.
    ///
    /// A 404 is the expected answer for most of a pairing attempt: it means the
    /// operator has not approved the device yet. Anything else is reported,
    /// since a misconfigured discovery host would otherwise look identical to a
    /// user who is simply slow to approve.
    ///
    /// - Parameter session: injected so this can be driven over the tailnet
    ///   once the device is a member, and stubbed in tests.
    public static func pollForRecord(
        slot: String,
        host: String = defaultHost,
        interval: TimeInterval = defaultInterval,
        timeout: TimeInterval = defaultTimeout,
        session: URLSession = .shared
    ) async throws -> Data {
        guard let url = recordURL(slot: slot, host: host) else {
            throw PairingRecord.PairingError.malformedSecret
        }
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            try Task.checkCancellation()

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            // Network errors are tolerated the same way a 404 is: a device may
            // be pairing over a connection that is still coming up.
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    return data
                }
                if http.statusCode != 404 {
                    throw DiscoveryError.unexpectedStatus(http.statusCode)
                }
            }

            if Date().addingTimeInterval(interval) > deadline {
                throw DiscoveryError.timedOut
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
