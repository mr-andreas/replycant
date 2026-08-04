import XCTest
@testable import iosapp

/// Verifies the double-tap zoom rect computation so taps zoom toward the
/// tapped point rather than always centering the zoom on the image midpoint.
final class DoubleTapZoomRectTests: XCTestCase {

    // At 2.5x zoom the rect should be 1/2.5 the scroll view size in each dimension.
    func testZoomRect_dimensionsMatchTargetScale() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let center = CGPoint(x: 200, y: 400)

        let rect = DoubleTapZoomRect.zoomRect(for: scrollView, scale: 2.5, center: center)

        XCTAssertEqual(rect.width, 160, accuracy: 0.01)
        XCTAssertEqual(rect.height, 320, accuracy: 0.01)
    }

    // The rect should be centered on the tapped point.
    func testZoomRect_centeredOnTapPoint() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let center = CGPoint(x: 100, y: 200)

        let rect = DoubleTapZoomRect.zoomRect(for: scrollView, scale: 2.0, center: center)

        let expectedWidth: CGFloat = 200
        let expectedHeight: CGFloat = 400
        XCTAssertEqual(rect.origin.x, center.x - expectedWidth / 2, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, center.y - expectedHeight / 2, accuracy: 0.01)
    }

    // At 1x zoom the rect should equal the full scroll view bounds.
    func testZoomRect_scale1x_returnsFullBounds() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let center = CGPoint(x: 150, y: 300)

        let rect = DoubleTapZoomRect.zoomRect(for: scrollView, scale: 1.0, center: center)

        XCTAssertEqual(rect.width, 300, accuracy: 0.01)
        XCTAssertEqual(rect.height, 600, accuracy: 0.01)
    }

    // Verifies that tapping near the edge produces a rect that extends
    // beyond image bounds, which is fine because UIScrollView clamps it.
    func testZoomRect_tapNearEdge_producesNegativeOrigin() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let center = CGPoint(x: 10, y: 10)

        let rect = DoubleTapZoomRect.zoomRect(for: scrollView, scale: 2.5, center: center)

        XCTAssertLessThan(rect.origin.x, 0)
        XCTAssertLessThan(rect.origin.y, 0)
    }

    // Typical iPhone photo viewer: 393x852 screen, tap center, zoom 2.5x
    func testZoomRect_realWorldiPhone() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let center = CGPoint(x: 200, y: 400)

        let rect = DoubleTapZoomRect.zoomRect(for: scrollView, scale: 2.5, center: center)

        let expectedWidth = 393.0 / 2.5
        let expectedHeight = 852.0 / 2.5
        XCTAssertEqual(rect.width, expectedWidth, accuracy: 0.01)
        XCTAssertEqual(rect.height, expectedHeight, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 200, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 400, accuracy: 0.01)
    }
}
