import Foundation
import Testing
@testable import iosapp

#if DEBUG
// A simulator cannot scan, so the already-paired device grants access
// from a debug link carrying the new device's QR JSON. These tests pin
// that URL so a recovery link, a first-device join, or a second link
// while a grant is running cannot start the wrong flow.
struct DebugDeviceLinkTests {
    // '+' '/' and '&' are the characters a URL query would split or
    // decode wrong. The parser has to hand them back unchanged.
    private static let deviceJSON = #"{"pubkey":"ecdsa AAAA+/=&x","age_pubkey":"age1qq","name":"iphone","uuid":"abc-1","pairing_secret":"c2VjcmV0"}"#

    @Test func validLinkReturnsTheDeviceFields() {
        let parsed = DebugDeviceLink.payload(from: link(payload: Self.deviceJSON))
        #expect(parsed?.pubkey == "ecdsa AAAA+/=&x")
        #expect(parsed?.agePubkey == "age1qq")
        #expect(parsed?.name == "iphone")
        #expect(parsed?.uuid == "abc-1")
        #expect(parsed?.pairingSecret == "c2VjcmV0")
    }

    @Test func wrongSchemeIsIgnored() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "debug-link-device"
        components.queryItems = [URLQueryItem(name: "payload", value: Self.deviceJSON)]
        #expect(DebugDeviceLink.payload(from: components.url!) == nil)
    }

    @Test func wrongHostIsIgnored() {
        var components = URLComponents()
        components.scheme = "replycant"
        components.host = "debug-bootstrap"
        components.queryItems = [URLQueryItem(name: "payload", value: Self.deviceJSON)]
        #expect(DebugDeviceLink.payload(from: components.url!) == nil)
    }

    // A join or a recovery key must not grant a device. Those URLs
    // already belong to other flows.
    @Test func bootstrapAndRecoveryLinksAreNotMatched() {
        let bootstrap = URL(string: "replycant://debug-bootstrap?payload=%7B%7D")!
        let recovery = URL(string: "replycant://recover?v=1&d=abc&keep=1")!
        #expect(DebugDeviceLink.payload(from: bootstrap) == nil)
        #expect(DebugDeviceLink.payload(from: recovery) == nil)
    }

    @Test func incompleteDeviceJSONIsIgnored() {
        let missingSecret = #"{"pubkey":"k","age_pubkey":"a","name":"iphone","uuid":"abc-1"}"#
        let blankSecret = #"{"pubkey":"k","age_pubkey":"a","name":"iphone","uuid":"abc-1","pairing_secret":"  "}"#
        #expect(DebugDeviceLink.payload(from: link(payload: missingSecret)) == nil)
        #expect(DebugDeviceLink.payload(from: link(payload: blankSecret)) == nil)
    }

    // Opening the link twice before the first grant finishes would push
    // the same key twice and spend the pairing attempt.
    @Test @MainActor func secondLinkWhileGrantingIsIgnored() async {
        let probe = GrantProbe()
        let router = DebugDeviceLinkRouter { payload in
            await probe.begin(payload.name)
        }
        let url = link(payload: Self.deviceJSON)
        router.handle(url: url)
        router.handle(url: url)
        let names = await probe.finish()
        #expect(names == ["iphone"])
    }

    private func link(payload: String) -> URL {
        var components = URLComponents()
        components.scheme = "replycant"
        components.host = "debug-link-device"
        components.queryItems = [URLQueryItem(name: "payload", value: payload)]
        return components.url!
    }
}

// Holds the first grant open so the test can deliver a second link
// before that grant returns.
private actor GrantProbe {
    private var names: [String] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func begin(_ name: String) async {
        names.append(name)
        await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
            waiter = pending
        }
    }

    func finish() async -> [String] {
        while waiter == nil {
            await Task.yield()
        }
        waiter?.resume()
        waiter = nil
        return names
    }
}
#endif
