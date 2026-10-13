import CoreImage
import UIKit

// Reads the text out of a QR image. The simulator has no camera, so a
// debug build can paste the bootstrap code instead of scanning it.
enum QRImageDecoder {
    // Returns the first QR payload in the image. A photo, a screenshot
    // of something else, or unreadable bytes yield nil so the scanner
    // can show its usual rejection instead of acting on garbage.
    static func decode(imageData: Data) -> String? {
        guard let image = CIImage(data: imageData) else {
            return nil
        }
        if let code = message(in: image) {
            return code
        }
        // The CA page serves a 256px indexed PNG. CIDetector misses that
        // until the modules are enlarged, so a failed pass retries bigger.
        let shortest = min(image.extent.width, image.extent.height)
        guard shortest > 1, shortest < 768 else {
            return nil
        }
        let factor = 768 / shortest
        let enlarged = image.transformed(
            by: CGAffineTransform(scaleX: factor, y: factor)
        )
        // The transform only changes the extent. Rasterize so the
        // detector sees larger modules instead of the original samples.
        guard let rendered = rasterized(enlarged) else {
            return nil
        }
        return message(in: rendered)
    }

    // Draws the image into a bitmap. A CIImage transform is not enough
    // for the detector, which otherwise samples the unscaled pixels.
    private static func rasterized(_ image: CIImage) -> CIImage? {
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }

    // Returns the first QR string in the image, if the detector can see one.
    private static func message(in image: CIImage) -> String? {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: image) ?? []
        for feature in features {
            if let code = (feature as? CIQRCodeFeature)?.messageString,
               !code.isEmpty {
                return code
            }
        }
        return nil
    }
}
