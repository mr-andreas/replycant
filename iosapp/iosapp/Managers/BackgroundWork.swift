import Foundation

// Runs blocking upload work below UI priority so an in-flight sync cannot
// starve pan, zoom, and timeline scrolling of their frame budget.
enum BackgroundWork {
    // Hops to a utility-priority executor. The caller yields first because a
    // detached task that has already finished does not suspend, and upload
    // runs on the main actor.
    static func run<T: Sendable>(
        _ body: @Sendable @escaping () throws -> T
    ) async throws -> T {
        await Task.yield()
        return try await Task.detached(priority: .utility) {
            try body()
        }.value
    }
}
