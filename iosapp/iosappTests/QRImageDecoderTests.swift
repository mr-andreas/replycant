import Testing
import UIKit
@testable import iosapp

// The simulator cannot photograph the bootstrap QR, so a pasted image
// has to yield the same text the camera would have read.
struct QRImageDecoderTests {
    private static let joinJSON = #"{"ca":"pem","headscale_url":"https://hs.example","preauth_key":"hskey-1"}"#

    // A pasted copy of the CA page QR, at the 256px size that page
    // serves, has to yield the same join text the camera would have read.
    @Test func qrImageDecodesToItsPayload() throws {
        let image = try #require(
            QRCodeDisplayView.generateQRCodeImage(
                from: Self.joinJSON,
                side: 256,
                correctionLevel: "M"
            )
        )
        let data = try #require(image.pngData())
        #expect(QRImageDecoder.decode(imageData: data) == Self.joinJSON)
    }

    @Test func plainImageDecodesToNil() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let data = try #require(image.pngData())
        #expect(QRImageDecoder.decode(imageData: data) == nil)
    }
}
