import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// A QR code for a text, drawn with CoreImage's `CIQRCodeGenerator` (the
/// Pair Nearby Device sheet's Android path shows one).
enum QRCodeImage {
    /// The code as a crisp bitmap: `scale` device pixels per module, a quiet
    /// zone of four modules, black on white (a phone camera needs the
    /// contrast in both appearances). Nil when the text cannot be encoded.
    static func cgImage(for text: String, scale: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // The generator's output is one pixel per module, without a quiet zone.
        let quiet: CGFloat = 4
        let padded = output
            .transformed(by: CGAffineTransform(translationX: quiet, y: quiet))
            .composited(over: CIImage(color: .white).cropped(to: CGRect(
                x: 0, y: 0,
                width: output.extent.width + 2 * quiet,
                height: output.extent.height + 2 * quiet
            )))
        // Nearest-neighbour, so the integer scale keeps every module sharp.
        let sharp = padded
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(sharp, from: sharp.extent)
    }

    static func nsImage(for text: String, points: CGFloat) -> NSImage? {
        guard let image = cgImage(for: text) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: points, height: points))
        return result
    }
}
