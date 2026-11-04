import Combine
import CoreGraphics
import Foundation

// The app state an index grid reads and reports into.
//
// The grid does not know what a row is. It asks which id sits at an
// index, tells the model which indices are on screen, and keeps the
// scroll position the model persists across remounts. The model owns
// which pages and which nearby indices get loaded.
@MainActor
public protocol SparseGridModel: AnyObject {
    var totalCount: Int { get }
    var totalCountPublisher: AnyPublisher<Int, Never> { get }
    var revisionPublisher: AnyPublisher<Int, Never> { get }
    var scrollTargetIndex: Int? { get set }
    // Emits when a month jump asks the grid to move. The grid clears
    // the value once it has consumed the request.
    var scrollTargetIndexPublisher: AnyPublisher<Int?, Never> { get }
    var isGridScrolling: Bool { get }
    var savedContentOffset: CGPoint? { get set }
    var savedViewportAnchorIndex: Int? { get set }
    var savedViewportAnchorOffsetFromItemTop: CGFloat? { get set }
    var savedGridWidth: CGFloat? { get set }

    func itemId(at index: Int) -> String?
    func index(ofItemId id: String) -> Int?
    func schedulePaging(around index: Int)
    func itemDidAppear(at index: Int)
    func itemDidDisappear(at index: Int)
    func setGridScrolling(_ scrolling: Bool)
    func updateCurrentMonth(for index: Int?, force: Bool)
}

// A cell that remembers which id it is showing. After a sync moves
// the index, the grid reads this so the photo on screen stays the one
// the person tapped or was looking at.
public protocol SparseGridCell: AnyObject {
    var sparseItemId: String? { get }
}
