import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import BounceKit

/// Renders `string` as a crisp QR code (nearest-neighbour upscaled).
enum QRCodeImage {
    static func make(_ string: String, size: CGFloat = 160) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (size / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// "Get Bounce for iPhone": the pairing QR plus the install link as
/// selectable text. Shown before the pairing step and in Settings → Sync.
struct GetIPhoneAppView: View {
    @Environment(TransferManager.self) private var transferManager

    var body: some View {
        VStack(spacing: 10) {
            Text("Get Bounce for iPhone")
                .font(.headline)

            if let qr = QRCodeImage.make(transferManager.pairingURL?.absoluteString ?? BounceConstants.iPhoneAppURL) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("QR code to pair the Bounce iPhone app with this Mac")
            }

            Text("Scan with your iPhone camera to join the Bounce beta on TestFlight, then open it to pair.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)

            Text("Mac and iPhone need to be on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(BounceConstants.iPhoneAppURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
