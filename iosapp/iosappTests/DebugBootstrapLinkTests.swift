import Foundation
import Testing
@testable import iosapp

#if DEBUG
// A debug deep link is how a simulator joins a new library without a
// camera. These tests pin the URL shape so a recovery link, or a join
// missing its credential, cannot start bootstrap.
struct DebugBootstrapLinkTests {
    private static let joinJSON = #"{"ca":"a+b/c=&d","headscale_url":"https://hs.example","preauth_key":"hskey-1"}"#

    // The agent percent-encodes /config.json into the query. The parser
    // has to return that JSON unchanged, including characters a URL
    // would otherwise treat as separators.
    @Test func validLinkReturnsThePayloadJSON() {
        let url = link(payload: Self.joinJSON)
        #expect(DebugBootstrapLink.payload(from: url) == Self.joinJSON)
    }

    @Test func wrongSchemeIsIgnored() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "debug-bootstrap"
        components.queryItems = [URLQueryItem(name: "payload", value: Self.joinJSON)]
        let url = components.url!
        #expect(DebugBootstrapLink.payload(from: url) == nil)
    }

    @Test func wrongHostIsIgnored() {
        var components = URLComponents()
        components.scheme = "replycant"
        components.host = "recover"
        components.queryItems = [URLQueryItem(name: "payload", value: Self.joinJSON)]
        let url = components.url!
        #expect(DebugBootstrapLink.payload(from: url) == nil)
    }

    // The same rejection the camera applies: a join without a preauth
    // key, or with a blank field, must not be handed to onboarding.
    @Test func incompleteOrBlankJoinIsIgnored() {
        let missingKey = #"{"ca":"pem","headscale_url":"https://hs.example"}"#
        let blankKey = #"{"ca":"pem","headscale_url":"https://hs.example","preauth_key":"  "}"#
        #expect(DebugBootstrapLink.payload(from: link(payload: missingKey)) == nil)
        #expect(DebugBootstrapLink.payload(from: link(payload: blankKey)) == nil)
    }

    // Recovery already owns replycant://. Matching it here would start
    // a bootstrap from a key the user meant to restore with.
    @Test func recoveryLinkIsNotMatched() {
        let url = URL(string: "replycant://recover?v=1&d=abc&keep=1")!
        #expect(DebugBootstrapLink.payload(from: url) == nil)
    }

    // Builds the link the way simctl will open it, so the test encodes
    // the payload instead of handing the parser a raw string.
    private func link(payload: String) -> URL {
        var components = URLComponents()
        components.scheme = "replycant"
        components.host = "debug-bootstrap"
        components.queryItems = [URLQueryItem(name: "payload", value: payload)]
        return components.url!
    }
}
#endif
