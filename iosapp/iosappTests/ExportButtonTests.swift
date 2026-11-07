import Testing
import UIKit
@testable import iosapp

// Share and Save used to do nothing. A tap never ran the touch-up
// action, and a parent gesture or the pager could take the press.
@MainActor
@Suite("Export Button Tests", .serialized)
struct ExportButtonTests {
    private func makeItem(id: String, mediaType: String) -> TimelineItem {
        let manifest = OriginalManifest(
            id: id,
            localID: nil,
            sha256: "sha-\(id)",
            path: "\(id).dat",
            filesize: 1024,
            name: id,
            deviceSpace: "device-space-1",
            mediaType: mediaType,
            width: 1920,
            height: 1080,
            modifiedAt: nil,
            duration: mediaType == "video" ? 12.0 : nil,
            mimeType: mediaType == "video" ? "video/mp4" : "image/jpeg",
            location: nil,
            isFavorite: false,
            isHidden: false,
            burstIdentifier: nil,
            createdAt: Date(),
            takenAt: Date(),
            clientCTime: nil,
            guessedTakenAt: Date()
        )
        return TimelineItem(original: manifest)
    }

    private func makePage(mediaType: String) -> FullScreenMediaPageViewController {
        let item = makeItem(id: "export-\(mediaType)", mediaType: mediaType)
        let manager = TimelineManager(notificationCenter: NotificationCenter())
        manager.seedLoadedRegionForTesting(offset: 0, items: [item], totalCount: 1)
        return FullScreenMediaPageViewController(
            initialItemId: item.id,
            timelineManager: manager,
            onDismiss: {}
        )
    }

    private func findButton(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func host(_ page: FullScreenMediaPageViewController) -> (UIWindow, UIPanGestureRecognizer) {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = UIWindow(frame: frame)
        let host = UIViewController()
        let pan = UIPanGestureRecognizer()
        host.view.addGestureRecognizer(pan)
        host.view.frame = frame
        host.addChild(page)
        page.view.frame = frame
        host.view.addSubview(page.view)
        page.didMove(toParent: host)
        window.rootViewController = host
        window.makeKeyAndVisible()
        page.loadViewIfNeeded()
        host.view.layoutIfNeeded()
        return (window, pan)
    }

    // The pager can be reordered above the buttons. A tap at the button
    // must still hit the button.
    @Test func saveButtonStaysHitTargetWhenThePagerIsInFront() throws {
        let page = makePage(mediaType: "photo")
        let (window, _) = host(page)
        defer { window.isHidden = true }
        page.viewDidAppear(false)

        let save = try #require(findButton("saveMediaButton", in: page.view))
        #expect(save.bounds.width == 44)
        page.view.bringSubviewToFront(page.testingPageViewController.view)
        let point = save.convert(
            CGPoint(x: save.bounds.midX, y: save.bounds.midY),
            to: page.view
        )

        let hit = page.view.hitTest(point, with: nil)

        #expect(hit === save)
    }

    // An accessibility tap is not a touch-up. Save still has to start.
    @Test func accessibilityActivateStartsSave() throws {
        let page = makePage(mediaType: "photo")
        let (window, _) = host(page)
        defer { window.isHidden = true }

        let save = try #require(findButton("saveMediaButton", in: page.view))
        #expect(save.accessibilityActivate())
        #expect(save.accessibilityLabel == "Saving")
        page.viewWillDisappear(false)
    }

    // Touch-up and the primary action both arrive for one press. The
    // second must not cancel the export the first one started.
    @Test func onePressDoesNotCancelTheExportItStarted() throws {
        let page = makePage(mediaType: "video")
        let (window, _) = host(page)
        defer { window.isHidden = true }

        let save = try #require(findButton("saveMediaButton", in: page.view))
        save.sendActions(for: .touchUpInside)
        save.sendActions(for: .primaryActionTriggered)

        #expect(save.accessibilityLabel == "Downloading video. Tap to cancel.")
        page.viewWillDisappear(false)
    }

    // A parent gesture used to take the press. It has to keep its other
    // answers and still ignore the buttons.
    @Test func parentGestureKeepsItsDelegateAndYieldsTheButtons() throws {
        final class Probe: NSObject, UIGestureRecognizerDelegate {
            var simultaneous = false
            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                simultaneous = true
                return true
            }
        }

        let page = makePage(mediaType: "photo")
        let (window, pan) = host(page)
        defer { window.isHidden = true }
        let probe = Probe()
        pan.delegate = probe
        page.view.setNeedsLayout()
        page.view.layoutIfNeeded()

        let save = try #require(findButton("saveMediaButton", in: page.view))
        #expect(pan.delegate !== probe)
        let allowed = pan.delegate?.gestureRecognizer?(
            pan,
            shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()
        )
        #expect(allowed == true)
        #expect(probe.simultaneous)

        let image = UIView()
        save.addSubview(image)
        #expect(
            ExportTouchPolicy.gestureShouldReceiveTouch(on: save, exportButtons: [save]) == false
        )
        #expect(
            ExportTouchPolicy.gestureShouldReceiveTouch(on: image, exportButtons: [save]) == false
        )
        #expect(
            ExportTouchPolicy.gestureShouldReceiveTouch(on: page.view, exportButtons: [save]) == true
        )
    }
}
