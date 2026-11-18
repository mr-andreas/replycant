import Foundation
import LibGit2
import Synchronization
import Testing
@testable import iosapp

// Locks the UI-test launch contract: fixture setup must not finish before
// the caller returns. XCTest drops the launch when that work stays on the
// main thread long enough to miss the background assertion.
struct TestSupportLaunchTests {

    @Test func scheduleRepositoryPreparationReturnsBeforeTheWorkFinishes() async {
        let finished = Mutex(false)

        TestSupport.scheduleRepositoryPreparation {
            try? await Task.sleep(for: .milliseconds(400))
            finished.withLock { $0 = true }
        }

        #expect(finished.withLock { $0 } == false)

        await TestSupport.waitUntilRepositoryPrepared()
        #expect(finished.withLock { $0 })
    }

    // A simulator used for a real library keeps its tailnet config. The
    // launch join would drop the fixture LFS route, so UI-test setup has
    // to forget that config before any join starts.
    @Test func isolateUITestNetworkDropsAStoredTailnetBeforeTheJoin() async throws {
        let name = "replycant.tests.uitest-tailnet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let configurations = TailnetConfigurationManager(defaults: defaults)
        configurations.save(
            try TailnetConfigurationManager.from(headscaleURL: "https://hs.example.com")
        )
        let router = TailnetSessionRouter()

        TestSupport.isolateUITestNetwork(
            configurations: configurations,
            router: router
        )

        let bootstrap = TailnetBootstrap(configurations: configurations, router: router)
        try await bootstrap.ensureJoinedIfConfigured()

        #expect(configurations.load() == nil)
        let session = URLSessionConfiguration.ephemeral
        #expect(router.applySynchronously(to: session))
    }
}
