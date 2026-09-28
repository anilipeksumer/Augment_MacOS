import AppKit
import CoreImage

/// Extracts a single representative color from artwork, used to tint the
/// notch's ambient glow the way system "Now Playing" surfaces do.
extension NSImage {
    func averageColor() -> NSColor? {
        guard let tiff = tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }

        let extentVector = CIVector(
            x: ciImage.extent.origin.x, y: ciImage.extent.origin.y,
            z: ciImage.extent.size.width, w: ciImage.extent.size.height
        )

        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: extentVector]
        ), let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            outputImage, toBitmap: &bitmap, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )

        return NSColor(
            red: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255, alpha: 1
        )
    }

    /// Boosts saturation/brightness so pale or muddy artwork still reads as
    /// a vivid ambient tint instead of washing out to gray.
    func vividAmbientColor() -> NSColor {
        guard let base = averageColor(), let hsb = base.usingColorSpace(.deviceRGB) else {
            return NSColor.white.withAlphaComponent(0.5)
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        s = min(1, max(s, 0.45))
        b = min(1, max(b, 0.55))
        return NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
    }
}
