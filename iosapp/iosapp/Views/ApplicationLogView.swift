import SwiftUI
import UIKit

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
            .sheet(item: $shareItem) { item in
                ActivityShareSheet(items: [item.url])
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

    // Copies the log to a .txt file and presents the system share
    // sheet so Mail, Files, and AirDrop attach that file.
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
