import SwiftUI
import CoreImage.CIFilterBuiltins

// Displays JSON data as a QR code for device linking and configuration sharing.
// Uses CoreImage's CIQRCodeGenerator to render QR codes with high error correction.
struct QRCodeDisplayView: View {
    let data: String
    let title: String
    let subtitle: String?
    let borderColor: Color?
    let qrSide: CGFloat
    let correctionLevel: String
    
    init(
        data: String,
        title: String,
        subtitle: String? = nil,
        borderColor: Color? = nil,
        qrSide: CGFloat = 260,
        correctionLevel: String = "H"
    ) {
        self.data = data
        self.title = title
        self.subtitle = subtitle
        self.borderColor = borderColor
        self.qrSide = qrSide
        self.correctionLevel = correctionLevel
    }

    // Exposes whether this QR card should render a phase border so tests can
    // enforce the Step 2 visual distinction contract.
    var hasBorder: Bool {
        borderColor != nil
    }
    
    var body: some View {
        VStack(spacing: 16) {
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }

            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            if let qrImage = QRCodeDisplayView.generateQRCodeImage(from: data, side: qrSide, correctionLevel: correctionLevel) {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: qrSide, maxHeight: qrSide)
                    .padding(16)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(borderColor ?? .clear, lineWidth: hasBorder ? 2.5 : 0)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.2))
                    .frame(maxWidth: qrSide, maxHeight: qrSide)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Text("Failed to generate QR code")
                            .foregroundColor(.secondary)
                    )
            }
        }
        .padding()
    }
    
    // Generates a UIImage QR code from the provided string using CoreImage.
    // Returns a high-resolution QR code with error correction level H.
    static func generateQRCodeImage(from string: String, side: CGFloat = 260, correctionLevel: String = "H") -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        guard let data = string.data(using: .utf8) else {
            logError("Failed to convert string to data for QR code", context: "QRCode")
            return nil
        }
        
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        
        guard let outputImage = filter.outputImage else {
            logError("Failed to generate QR code image", context: "QRCode")
            return nil
        }
        
        let scaleX = side / outputImage.extent.size.width
        let scaleY = side / outputImage.extent.size.height
        let transformedImage = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else {
            logError("Failed to create CGImage from CIImage", context: "QRCode")
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
}

#Preview("With Subtitle") {
    QRCodeDisplayView(
        data: "{\"pubkey\":\"ssh-ed25519 AAAA...\",\"name\":\"my-iphone\"}",
        title: "my-iphone",
        subtitle: "Device Public Key"
    )
}

#Preview("Without Subtitle") {
    QRCodeDisplayView(
        data: "{\"url\":\"https://git.example.com\",\"ca\":\"...\"}",
        title: "Scan on New Device"
    )
}
