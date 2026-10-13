import Testing
import UIKit
@testable import iosapp

// The simulator cannot photograph the bootstrap QR, so a pasted image
// has to yield the same text the camera would have read.
struct QRImageDecoderTests {
    private static let joinJSON = #"{"ca":"pem","headscale_url":"https://hs.example","preauth_key":"hskey-1"}"#

    // 20px is below what the detector reads on its own. The CA page PNG
    // has the same problem at its native size, so this locks the enlarge
    // pass rather than a code that was already large enough.
    @Test func qrImageDecodesToItsPayload() throws {
        let image = try #require(
            QRCodeDisplayView.generateQRCodeImage(from: Self.joinJSON, side: 20)
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
