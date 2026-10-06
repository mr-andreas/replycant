import Foundation
import Testing
@testable import iosapp

// Pins the grant path that runs after a pairing QR scan.
//
// The existing device used to do commit+push on the view's MainActor Task,
// which froze the UI for the whole network round trip. These cases exist so
// that hop cannot silently move back onto the main thread, and so a failed
// key-add cannot still fire tailnet authorization.
struct DeviceLinkingGrantTests {
    private enum GrantTestError: Error {
        case addFailed
    }

    // Records which grant steps ran and whether add-keys was on the main
    // thread, because that is the freeze the scan path has to avoid.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        private var addDeviceKeyOnMainThread: Bool?

        func record(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func recordAddDeviceKeyIsolation() {
            lock.lock()
            addDeviceKeyOnMainThread = Thread.isMainThread
            lock.unlock()
        }

        func snapshot() -> (events: [String], addDeviceKeyOnMainThread: Bool?) {
            lock.lock()
            defer { lock.unlock() }
            return (events, addDeviceKeyOnMainThread)
        }
    }

    // Builds operations that record isolation and step order without touching
    // a real repository or gitd.
    private func operations(
        recorder: Recorder,
        addDeviceKey: (@Sendable () async throws -> Void)? = nil
    ) -> DeviceLinking.Operations {
        DeviceLinking.Operations(
            addDeviceKey: { _, _, _, _, _ in
                recorder.recordAddDeviceKeyIsolation()
                recorder.record("add")
                if let addDeviceKey {
                    try await addDeviceKey()
                }
            },
            authorize: { _, _, _ in
                recorder.record("authorize")
            }
        )
    }

    // A MainActor caller is the production scan path. Add-keys has to leave
    // that actor or the spinner and touches freeze for the whole push.
    @Test @MainActor
    func addDeviceKeyRunsOffMainActor() async throws {
        let recorder = Recorder()
        try await DeviceLinking.grantAccess(
            pubkey: "ssh-ed25519 AAAA",
            agePubkey: "age1example",
            name: "iphone",
            uuid: "device-uuid",
            pairingSecret: "pairing-secret",
            operations: operations(recorder: recorder)
        )

        let snapshot = recorder.snapshot()
        #expect(snapshot.addDeviceKeyOnMainThread == false)
        #expect(snapshot.events == ["add", "authorize"])
    }

    // Tailnet onboarding is waiting on a sealed record. Skipping authorize
    // after a successful key-add leaves that device polling until timeout.
    @Test
    func pairingSecretAuthorizesAfterAddingKeys() async throws {
        let recorder = Recorder()
        try await DeviceLinking.grantAccess(
            pubkey: "ssh-ed25519 AAAA",
            agePubkey: "age1example",
            name: "iphone",
            uuid: "device-uuid",
            pairingSecret: "pairing-secret",
            operations: operations(recorder: recorder)
        )

        #expect(recorder.snapshot().events == ["add", "authorize"])
    }

    // The new device is still unknown to gitd until the key is pushed.
    // Authorizing a failed add would mint a credential the clone cannot use.
    @Test
    func addDeviceKeyFailureSkipsAuthorize() async {
        let recorder = Recorder()
        await #expect(throws: GrantTestError.addFailed) {
            try await DeviceLinking.grantAccess(
                pubkey: "ssh-ed25519 AAAA",
                agePubkey: "age1example",
                name: "iphone",
                uuid: "device-uuid",
                pairingSecret: "pairing-secret",
                operations: operations(recorder: recorder) {
                    throw GrantTestError.addFailed
                }
            )
        }

        #expect(recorder.snapshot().events == ["add"])
    }
}
