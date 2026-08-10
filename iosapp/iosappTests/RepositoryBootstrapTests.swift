import Testing
@testable import iosapp

// Verifies bootstrap progress scaling remains stable across onboarding, resync, and recovery flows.
struct RepositoryBootstrapTests {
    // Ensures midpoint percentages map linearly into the caller's configured progress band.
    @Test func scaledMapsIntoRange() {
        #expect(RepositoryBootstrap.scaled(50, into: 20...80) == 50)
    }

    // Ensures negative percentages clamp to the lower bound to avoid regressions from noisy callbacks.
    @Test func scaledClampsLowerBound() {
        #expect(RepositoryBootstrap.scaled(-10, into: 35...70) == 35)
    }

    // Ensures over-100 percentages clamp to the upper bound so progress bars do not overshoot.
    @Test func scaledClampsUpperBound() {
        #expect(RepositoryBootstrap.scaled(140, into: 75...95) == 95)
    }
}
