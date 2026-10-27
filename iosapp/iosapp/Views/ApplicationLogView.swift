import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Shows the retained diagnostic log and shares it as a text file.
// People need this after the debugger has detached, when the system
// log no longer has the info lines that explain a failure.
struct ApplicationLogView: View {
    private let previewText: String?
    @State private var text: String
    @State private var shareItem: ApplicationLogShare?
    @State private var isShowingShareError = false

    // Sample lines so the screen catalog can show the page without
    // reading the simulator's real log file.
    static let gallerySample = """
    [12:00:00.000][INFO][PhotoSync] Using repository
    [12:00:01.250][INFO][Git] pull finished
    [GitDB] sync complete
    """

    // Preview text stands in for the file so gallery tiles do not
    // depend on whatever the host process has logged.
    init(previewText: String? = nil) {
        self.previewText = previewText
        _text = State(initialValue: previewText ?? ApplicationLog.text())
    }

    var body: some View {
        LogTextView(text: displayedText)
            .navigationTitle("Application log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: share) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("shareApplicationLog")
                    .disabled(text.isEmpty)
                }
            }
            .onAppear(perform: reload)
            .overlay {
                ApplicationLogSharePresenter(url: shareItem?.url) {
                    shareItem = nil
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
            .alert("Couldn't share the log", isPresented: $isShowingShareError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The log file could not be copied.")
            }
    }

    // Placeholder copy is only for an empty screen. The share stays
    // disabled so that sentence is never attached as the log.
    private var displayedText: String {
        text.isEmpty ? "No log lines yet." : text
    }

    // Re-reads the file when the screen appears so lines written while
    // the person was reproducing a problem show up on the way back.
    private func reload() {
        guard previewText == nil else { return }
        text = ApplicationLog.text()
    }

    // Copies the log to a .txt file. The host below presents the
    // system share sheet so Mail, Files, and AirDrop attach that file.
    private func share() {
        do {
            let url: URL
            if let previewText {
                url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(ApplicationLog.shareFileName)
                try Data(previewText.utf8).write(to: url, options: .atomic)
            } else {
                url = try ApplicationLog.makeShareFile()
            }
            shareItem = ApplicationLogShare(url: url)
        } catch {
            isShowingShareError = true
        }
    }
}

// Identifies one exported file so the share sheet attaches the copy
// made at tap time.
private struct ApplicationLogShare: Identifiable {
    let id = UUID()
    let url: URL
}

// Hands the share sheet a file URL plus a header that does not point
// at that file. The system otherwise reads the whole log on the main
// thread to draw a preview, which freezes the app before the sheet
// appears.
final class ApplicationLogShareItem: NSObject, UIActivityItemSource {
    private let url: URL

    // Keeps the snapshot made at tap time so a later log line is not
    // pulled into this share.
    init(url: URL) {
        self.url = url
    }

    // Same type as the real item, so destinations that accept a text
    // file stay in the sheet. The URL itself is cheap; the bytes stay
    // on disk until a destination asks for them.
    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        url
    }

    // Returns the snapshot file to every destination so Mail, Files,
    // and AirDrop attach replycant-log.txt rather than untitled text.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    // Plain text keeps Copy, Mail, and Files from treating the log as
    // an unknown file they refuse to accept.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.plainText.identifier
    }

    // Title and icon only. A URL would send the system back to reading
    // the log to build the header, which is the freeze.
    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = ApplicationLog.shareFileName
        if let icon = UIImage(systemName: "doc.text") {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}

// Presents the share sheet from a controller that is actually on
// screen. A SwiftUI sheet whose content is the activity controller
// is dismissed as soon as a destination is chosen, which cancels the
// file before Mail or Files can read it.
private struct ApplicationLogSharePresenter: UIViewRepresentable {
    let url: URL?
    let onFinish: () -> Void

    // A clear anchor in the log's hierarchy. The background host this
    // replaced never joined a window, so the tap wrote a file and the
    // sheet never appeared.
    func makeUIView(context: Context) -> ApplicationLogShareAnchor {
        let anchor = ApplicationLogShareAnchor()
        anchor.isUserInteractionEnabled = false
        anchor.backgroundColor = .clear
        return anchor
    }

    // Pushes the latest snapshot into the anchor. SwiftUI calls this
    // on every refresh, including the one that clears the URL.
    func updateUIView(_ anchor: ApplicationLogShareAnchor, context: Context) {
        anchor.onFinish = onFinish
        anchor.share(url: url)
    }
}

// Finds the on-screen controller and keeps the share alive until the
// destination has read the file. The anchor itself does not present;
// it is not a view controller.
private final class ApplicationLogShareAnchor: UIView {
    var onFinish: () -> Void = {}
    private var presentedURL: URL?
    private var pendingURL: URL?

    // Queues the snapshot from this tap. A refresh of the same URL
    // does not open a second sheet.
    func share(url: URL?) {
        pendingURL = url
        presentPending()
    }

    // The first update can run before this anchor is in a window.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentPending()
    }

    // Walks up to a controller that can present, then to whatever that
    // controller is already showing, so the sheet is not hidden under it.
    private func presenter() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder {
            if let controller = next as? UIViewController, controller.view.window != nil {
                var top = controller
                while let presented = top.presentedViewController {
                    top = presented
                }
                return top
            }
            responder = next.next
        }
        return nil
    }

    // Presents after the SwiftUI update that queued the file, so the
    // call is not dropped for happening inside that update.
    private func presentPending() {
        guard let url = pendingURL, presentedURL != url else { return }
        guard window != nil, presenter()?.presentedViewController == nil else { return }
        presentedURL = url
        DispatchQueue.main.async { [weak self] in
            self?.presentNow(url)
        }
    }

    // Hands the file to the system sheet. The controller stays up
    // until the person finishes, which is when the file is released.
    private func presentNow(_ url: URL) {
        guard presentedURL == url, pendingURL == url else { return }
        guard let presenter = presenter(), presenter.presentedViewController == nil else {
            presentedURL = nil
            return
        }
        let controller = UIActivityViewController(
            activityItems: [ApplicationLogShareItem(url: url)],
            applicationActivities: nil
        )
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            let bounds = presenter.view.bounds
            let side: CGFloat = 44
            popover.sourceRect = CGRect(
                x: max(bounds.maxX - side, 0),
                y: bounds.minY,
                width: side,
                height: side
            )
        }
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.presentedURL = nil
            self?.pendingURL = nil
            self?.onFinish()
        }
        presenter.present(controller, animated: true)
    }
}

// UITextView rather than SwiftUI Text so a multi-megabyte log stays
// scrollable and selectable.
private struct LogTextView: UIViewRepresentable {
    let text: String

    // Builds a read-only text view. Editing is off so a tap cannot
    // change the diagnostic record the person is about to share.
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.accessibilityIdentifier = "applicationLog"
        return view
    }

    // Skips a no-op assignment so opening the screen does not jump
    // the scroll position back to the top on every SwiftUI refresh.
    func updateUIView(_ uiView: UITextView, context: Context) {
        guard uiView.text != text else { return }
        uiView.text = text
    }
}
