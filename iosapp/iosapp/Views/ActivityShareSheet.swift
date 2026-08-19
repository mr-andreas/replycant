import SwiftUI
import UIKit

// Bridges UIKit share sheet so recovery export can pass two
// independent activity items without SwiftUI wrapping each one.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    // Presents the system share sheet from the bundle's activity
    // items so each destination can pick the payloads it accepts.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
