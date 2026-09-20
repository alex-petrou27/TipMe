import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string as a QR code using Core Image's built-in generator — no
/// third-party dependency for something the system already does well.
struct QRCodeView: View {
    let content: String

    var body: some View {
        if let image = Self.render(content) {
            Image(uiImage: image)
                .interpolation(.none) // keep the modules crisp, not blurred
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                .fill(Theme.surfaceRaised)
                .overlay(Image(systemName: "qrcode").foregroundStyle(Theme.textTertiary))
        }
    }

    private static func render(_ string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        // The raw output is a handful of pixels; scale it up before rasterising
        // so it stays sharp rather than being upscaled blurrily by SwiftUI.
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = outputImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
