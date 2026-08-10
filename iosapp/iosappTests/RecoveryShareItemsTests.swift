import Testing
import UIKit
@testable import iosapp

// Verifies share payloads preserve formatting across app-specific share extensions.
struct RecoveryShareItemsTests {
    // Ensures mail-like targets receive HTML with preserved line breaks.
    @Test func mailActivityUsesHTMLText() throws {
        let source = RecoveryShareText(
            plainText: "Line one\nLine two",
            label: "home-safe"
        )

        let item = source.activityViewController(
            UIActivityViewController(activityItems: [], applicationActivities: nil),
            itemForActivityType: .mail
        )
        let identifier = source.activityViewController(
            UIActivityViewController(activityItems: [], applicationActivities: nil),
            dataTypeIdentifierForActivityType: .mail
        )

        let html = try #require(item as? String)
        #expect(html.contains("<br>"))
        #expect(!html.contains("\n"))
        #expect(identifier == "public.html")
    }

    // Ensures non-mail targets keep plain text payloads untouched.
    @Test func nonMailActivityUsesPlainText() {
        let source = RecoveryShareText(
            plainText: "Line one\nLine two",
            label: "home-safe"
        )
        let activity = UIActivity.ActivityType(rawValue: "org.whispersystems.signal.share")

        let item = source.activityViewController(
            UIActivityViewController(activityItems: [], applicationActivities: nil),
            itemForActivityType: activity
        )
        let identifier = source.activityViewController(
            UIActivityViewController(activityItems: [], applicationActivities: nil),
            dataTypeIdentifierForActivityType: activity
        )

        #expect((item as? String) == "Line one\nLine two")
        #expect(identifier == "public.plain-text")
    }

    // Ensures recipients that support a subject line receive contextual labeling.
    @Test func shareSubjectIncludesLabel() {
        let source = RecoveryShareText(
            plainText: "payload",
            label: "home-safe"
        )
        let subject = source.activityViewController(
            UIActivityViewController(activityItems: [], applicationActivities: nil),
            subjectForActivityType: .mail
        )

        #expect(subject == "Replycant recovery key: home-safe")
    }

    // Ensures the image payload includes caption space when the target keeps only one attachment.
    @Test func shareCardImageIncludesCaptionArea() {
        let qr = UIImage(systemName: "qrcode")!
        let rendered = RecoveryShareCard.render(
            qr: qr,
            label: "home-safe",
            uuid: "1234",
            host: "example.com"
        )

        #expect(rendered.size.height > qr.size.height)
    }
}
