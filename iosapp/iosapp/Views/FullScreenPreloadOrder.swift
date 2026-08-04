import Foundation

/// Computes the order in which neighbor images should be preloaded when
/// viewing a fullscreen image. Produces indices in outward-symmetric
/// order (+1, -1, +2, -2, ...) so the most likely next swipe targets
/// load first, regardless of swipe direction.
enum FullScreenPreloadOrder {

    /// Returns neighbor indices around `currentIndex` in alternating
    /// forward/backward order, clamped to `0..<count`.
    ///
    /// - Parameters:
    ///   - currentIndex: The index of the currently viewed item.
    ///   - count: Total number of items in the list.
    ///   - radius: How many positions to reach in each direction.
    /// - Returns: Ordered array of indices to preload (never includes
    ///   `currentIndex` itself).
    static func neighborIndices(currentIndex: Int, count: Int, radius: Int) -> [Int] {
        guard radius > 0, count > 1 else { return [] }

        var result: [Int] = []
        result.reserveCapacity(radius * 2)

        for offset in 1...radius {
            let forward = currentIndex + offset
            if forward < count {
                result.append(forward)
            }
            let backward = currentIndex - offset
            if backward >= 0 {
                result.append(backward)
            }
        }
        return result
    }
}
