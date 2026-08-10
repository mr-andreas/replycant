import UIKit

// Adapts recovery export text to destination app capabilities so recipients keep readable metadata.
final class RecoveryShareText: NSObject, UIActivityItemSource {
    private let plainText: String
    private let label: String

    init(plainText: String, label: String) {
        self.plainText = plainText
        self.label = label
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        plainText
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        if isMailActivity(activityType) {
            return htmlText
        }
        return plainText
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        isMailActivity(activityType) ? "public.html" : "public.plain-text"
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        "Replycant recovery key: \(label)"
    }

    private var htmlText: String {
        plainText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { escapeHTML(String($0)) }
            .joined(separator: "<br>")
    }

    private func isMailActivity(_ activityType: UIActivity.ActivityType?) -> Bool {
        guard let rawValue = activityType?.rawValue.lowercased() else {
            return false
        }
        return rawValue.contains("mail")
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// Provides an image-only backup payload for share extensions that keep only one attachment.
final class RecoveryShareImage: NSObject, UIActivityItemSource {
    private let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
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
        "public.png"
    }
}

// Renders QR code plus essential metadata so image-only shares still contain human-readable context.
enum RecoveryShareCard {
    static func render(qr: UIImage, label: String, uuid: String, host: String) -> UIImage {
        let qrSide = max(qr.size.width, 1)
        let horizontalMargin: CGFloat = 56
        let topMargin: CGFloat = 56
        let contentSpacing: CGFloat = 28
        let bottomMargin: CGFloat = 56
        let cardWidth = qrSide + (horizontalMargin * 2)

        let title = "Replycant recovery key"
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
