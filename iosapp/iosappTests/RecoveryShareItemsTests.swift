import LinkPresentation
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import iosapp

// Verifies the recovery share is two independent items: text for
// destinations that accept copy, and a UIImage for the QR card.
struct RecoveryShareItemsTests {
    private let cardImage = UIImage(systemName: "qrcode")!
    private let plainText = """
    \(RecoveryShareHeader.title)
    Deep link: replycant://recover?v=1&d=example
    """
    private let gmail = UIActivity.ActivityType(rawValue: "com.google.Gmail.ShareExtension")
    private let notes = UIActivity.ActivityType(rawValue: "com.apple.mobilenotes.SharingExtension")
    private let signal = UIActivity.ActivityType(
        rawValue: "org.whispersystems.signal.shareextension"
    )

    // Ensures every destination that asks the text item for content
    // receives the same pasteable backup.
    @Test func textItemReturnsPlainTextForDestinations() {
        let source = textItem()
        let controller = UIActivityViewController(
            activityItems: [],
            applicationActivities: nil
        )
        for activity in [gmail, notes, signal, .copyToPasteboard] {
            let item = source.activityViewController(
                controller,
                itemForActivityType: activity
            )
            #expect((item as? String) == plainText)
            #expect(
                source.activityViewController(
                    controller,
                    dataTypeIdentifierForActivityType: activity
                ) == UTType.plainText.identifier
            )
        }
    }

    // Ensures the share sheet header can render a titled Replycant
    // preview without a URL.
    @Test func textItemProvidesHeaderMetadata() {
        let metadata = textItem().activityViewControllerLinkMetadata(
            UIActivityViewController(activityItems: [], applicationActivities: nil)
        )

        #expect(metadata?.title == RecoveryShareHeader.title)
        #expect(metadata?.url == nil)
        #expect(metadata?.originalURL == nil)
        #expect(metadata?.iconProvider?.canLoadObject(ofClass: UIImage.self) == true)
    }

    // Ensures Mail receives a labeled subject so recipients can
    // identify the backup after they leave the share sheet.
    @Test func mailSubjectIncludesLabel() {
        let subject = textItem().activityViewController(
            UIActivityViewController(activityItems: [], applicationActivities: nil),
            subjectForActivityType: .mail
        )

        #expect(subject == "\(RecoveryShareHeader.title): home-safe")
    }

    // Ensures the image item hands destinations the same UIImage
    // Signal already renders inline.
    @Test func imageItemReturnsCardImage() {
        let source = RecoveryShareImageItem(image: cardImage)
        let controller = UIActivityViewController(
            activityItems: [],
            applicationActivities: nil
        )
        let item = source.activityViewController(
            controller,
            itemForActivityType: gmail
        )

        #expect((item as? UIImage) === cardImage)
        #expect(
            source.activityViewController(
                controller,
                dataTypeIdentifierForActivityType: gmail
            ) == UTType.png.identifier
        )
    }

    // Ensures the image item does not supply header metadata that
    // would replace the titled text preview.
    @Test func imageItemOmitsHeaderMetadata() {
        let metadata = RecoveryShareImageItem(image: cardImage)
            .activityViewControllerLinkMetadata(
                UIActivityViewController(activityItems: [], applicationActivities: nil)
            )

        #expect(metadata == nil)
    }

    // Ensures a card produces two independent items so destinations
    // can accept text and image as separate payloads.
    @Test func bundleWithCardCarriesTextAndImage() {
        let bundle = RecoveryShareBundle(
            plainText: plainText,
            label: "home-safe",
            cardImage: cardImage
        )

        #expect(bundle.items.count == 2)
        #expect(bundle.items[0] is RecoveryShareTextItem)
        #expect(bundle.items[1] is RecoveryShareImageItem)
    }

    // Ensures a missing QR card still exports the textual backup.
    @Test func bundleWithoutCardCarriesTextOnly() {
        let bundle = RecoveryShareBundle(
            plainText: plainText,
            label: "home-safe",
            cardImage: nil
        )

        #expect(bundle.items.count == 1)
        #expect(bundle.items[0] is RecoveryShareTextItem)
    }

    // Ensures each bundle has a unique id so assigning a new
    // instance can re-present the sheet after a previous dismiss.
    @Test func bundlesHaveDistinctIdentifiers() {
        let first = RecoveryShareBundle(
            plainText: plainText,
            label: "home-safe",
            cardImage: cardImage
        )
        let second = RecoveryShareBundle(
            plainText: plainText,
            label: "home-safe",
            cardImage: cardImage
        )

        #expect(first.id != second.id)
    }

    // Ensures the composed backup names the export, includes the
    // deep link, and warns that the password is not in the share.
    @Test func composeIncludesHeaderDeepLinkAndPasswordDisclaimer() {
        let deepLink = "replycant://recover?v=1&d=example"
        let text = RecoveryShareText.compose(
            label: "home-safe",
            uuid: "1234",
            host: "example.com",
            deepLink: deepLink
        )

        #expect(text.hasPrefix(RecoveryShareHeader.title))
        #expect(text.contains("Label: home-safe"))
        #expect(text.contains("ID: 1234"))
        #expect(text.contains("Server: example.com"))
        #expect(text.contains("Deep link: \(deepLink)"))
        #expect(text.contains("Password is required and is not included in this share."))
    }

    // Ensures the image placeholder is a real bitmap so image
    // activities stay in the sheet.
    @Test func imageItemPlaceholderIsNonEmptyImage() {
        let source = RecoveryShareImageItem(image: cardImage)
        let placeholder = source.activityViewControllerPlaceholderItem(
            UIActivityViewController(activityItems: [], applicationActivities: nil)
        )

        #expect((placeholder as? UIImage)?.size != .zero)
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

    // Builds the textual source so destination tests do not repeat
    // the same fixture setup.
    private func textItem() -> RecoveryShareTextItem {
        RecoveryShareTextItem(plainText: plainText, label: "home-safe")
    }
}
