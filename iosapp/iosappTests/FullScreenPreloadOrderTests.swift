import Foundation
import Testing
@testable import iosapp

// Verifies the outward-symmetric neighbor ordering used by fullscreen
// image preloading: +1, -1, +2, -2, ... clamped to the item bounds.
struct FullScreenPreloadOrderTests {

    @Test func middleOfList() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 5, count: 11, radius: 3
        )
        #expect(result == [6, 4, 7, 3, 8, 2])
    }

    @Test func radiusZeroReturnsEmpty() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 3, count: 10, radius: 0
        )
        #expect(result == [])
    }

    @Test func atStartOfList() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 0, count: 5, radius: 3
        )
        // +1, (skip -1), +2, (skip -2), +3, (skip -3)
        #expect(result == [1, 2, 3])
    }

    @Test func atEndOfList() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 4, count: 5, radius: 3
        )
        // (skip +1), -1, (skip +2), -2, (skip +3), -3
        #expect(result == [3, 2, 1])
    }

    @Test func radiusLargerThanList() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 1, count: 3, radius: 10
        )
        // +1, -1 — both other items
        #expect(result == [2, 0])
    }

    @Test func singleItemList() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 0, count: 1, radius: 5
        )
        #expect(result == [])
    }

    @Test func radiusOneMiddle() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 2, count: 5, radius: 1
        )
        #expect(result == [3, 1])
    }

    @Test func twoItemListFirstSelected() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 0, count: 2, radius: 3
        )
        #expect(result == [1])
    }

    @Test func twoItemListSecondSelected() {
        let result = FullScreenPreloadOrder.neighborIndices(
            currentIndex: 1, count: 2, radius: 3
        )
        #expect(result == [0])
    }
}
