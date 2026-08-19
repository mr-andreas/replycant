import LinkPresentation
import UniformTypeIdentifiers
import UIKit

// Hosts bundle lookup so tests and the share sheet find ReplycantLogo
// in the app target instead of the test bundle.
private final class RecoveryShareResourceAnchor {}

// Shared header copy so the text item, card, compose helper, and
// tests name the export the same way.
enum RecoveryShareHeader {
    static let title = "Replycant recovery key"
}

// Builds the pasteable backup so destinations that accept text can
// carry the deep link while the QR card remains the image fallback.
enum RecoveryShareText {
    static func compose(
        label: String,
        uuid: String,
        host: String,
        deepLink: String
    ) -> String {
        """
        \(RecoveryShareHeader.title)
        Label: \(label)
        ID: \(uuid)
        Server: \(host)
        Deep link: \(deepLink)

        Password is required and is not included in this share.
        """
    }
}

// Supplies the textual backup as its own activity item because one
// UIActivityItemSource can return only one payload per destination.
final class RecoveryShareTextItem: NSObject, UIActivityItemSource {
    private let plainText: String
    private let label: String

    // Carries the key label so Mail can name the message after
    // the share sheet is dismissed.
    init(plainText: String, label: String) {
        self.plainText = plainText
        self.label = label
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        plainText
    }

    // Returns the same backup to every destination so Gmail and
    // Copy receive the deep link when they ask for text.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        plainText
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.plainText.identifier
    }

    // Names the Mail subject so recipients can identify the backup
    // after they leave the share sheet.
    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        "\(RecoveryShareHeader.title): \(label)"
    }

    // Supplies title-and-icon metadata with no URL so the two-item
    // sheet can still name the export. The image item returns nil
    // so iOS does not replace this titled preview with an aggregate.
    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = RecoveryShareHeader.title
        if let icon = UIImage(
            named: "ReplycantLogo",
            in: Bundle(for: RecoveryShareResourceAnchor.self),
            compatibleWith: nil
        ) ?? UIImage(named: "ReplycantLogo") {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        return metadata
    }
}

// Supplies the QR card as a UIImage so destinations that keep an
// image can still recover the envelope from the encoded JSON.
final class RecoveryShareImageItem: NSObject, UIActivityItemSource {
    private let image: UIImage

    // Holds the rendered card so the share sheet can pass a real
    // UIImage to Signal and Notes.
    init(image: UIImage) {
        self.image = image
    }

    // Advertises the card so image activities stay in the sheet.
    // Returning the retained image avoids a dummy bitmap.
    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        image
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.png.identifier
    }

    // Leaves header metadata to the text item so iOS does not
    // replace the titled preview with a generic aggregate.
    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        nil
    }
}

// Groups the text and image sources so SwiftUI can present the
// share sheet from one Identifiable value.
struct RecoveryShareBundle: Identifiable {
    let id = UUID()
    let items: [Any]

    // Offers text first, then the card, so destinations that
    // accept both receive copy plus image. Gmail takes both,
    // Signal takes the image, and Notes keeps only the image.
    // Image-only is still recoverable: the QR encodes envelope
    // JSON that RecoveryBundle.parseEnvelope accepts directly.
    init(plainText: String, label: String, cardImage: UIImage?) {
        let text = RecoveryShareTextItem(plainText: plainText, label: label)
        if let cardImage {
            items = [text, RecoveryShareImageItem(image: cardImage)]
        } else {
            items = [text]
        }
    }
}

// Renders QR code plus essential metadata so image-only shares
// still contain human-readable context.
enum RecoveryShareCard {
    static func render(qr: UIImage, label: String, uuid: String, host: String) -> UIImage {
        let qrSide = max(qr.size.width, 1)
        let horizontalMargin: CGFloat = 56
        let topMargin: CGFloat = 56
        let contentSpacing: CGFloat = 28
        let bottomMargin: CGFloat = 56
        let cardWidth = qrSide + (horizontalMargin * 2)

        let title = RecoveryShareHeader.title
        let details = """
        Label: \(label)
        ID: \(uuid)
        Server: \(host)
        Password required, not included here.
        """

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: UIColor.black
        ]
        let detailsAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .regular),
            .foregroundColor: UIColor.darkGray
        ]

        let textWidth = cardWidth - (horizontalMargin * 2)
        let titleRect = NSString(string: title).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: titleAttributes,
            context: nil
        ).integral
        let detailsRect = NSString(string: details).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: detailsAttributes,
            context: nil
        ).integral

        let cardHeight = topMargin + qrSide + contentSpacing + titleRect.height + 12 + detailsRect.height + bottomMargin
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: cardWidth, height: cardHeight))

        return renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight)).fill()

            let qrRect = CGRect(
                x: horizontalMargin,
                y: topMargin,
                width: qrSide,
                height: qrSide
            )
            qr.draw(in: qrRect)

            let titleOrigin = CGPoint(
                x: horizontalMargin,
                y: qrRect.maxY + contentSpacing
            )
            NSString(string: title).draw(
                at: titleOrigin,
                withAttributes: titleAttributes
            )

            let detailsOrigin = CGPoint(
                x: horizontalMargin,
                y: titleOrigin.y + titleRect.height + 12
            )
            NSString(string: details).draw(
                with: CGRect(
                    x: detailsOrigin.x,
                    y: detailsOrigin.y,
                    width: textWidth,
                    height: detailsRect.height
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: detailsAttributes,
                context: nil
            )
        }
    }
}
