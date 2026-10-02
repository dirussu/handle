import Foundation
import CoreGraphics

/// Image preprocessing for the Claude API.
///
/// Per Clicky's playbook (and Anthropic's internal rescaling behavior), the most
/// reliable coordinate accuracy comes from sending images at a *known, modest*
/// resolution and explicitly telling Claude those exact pixel dimensions.
/// Sending native Retina pixels (e.g. 2880×1800) is counter-productive — the
/// vision tower rescales internally, and the model gets confused about which
/// coordinate space to use in its outputs.
enum ImagePreparation {
    /// Cap on the long edge of images we send to Claude. Matches Clicky and is
    /// near Anthropic's preferred resolution for vision.
    static let maxLongEdgePixels: CGFloat = 1280

    /// Resize the image (if needed) so its long edge is exactly `maxLongEdgePixels`,
    /// preserving aspect ratio. Does NOT upscale images smaller than the cap.
    /// Returns the resized image and its exact pixel dimensions.
    static func prepareForAPI(_ image: CGImage) -> (image: CGImage, pixelSize: CGSize) {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longEdge = max(w, h)
        if longEdge <= maxLongEdgePixels {
            return (image, CGSize(width: w, height: h))
        }
        let scale = maxLongEdgePixels / longEdge
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return (image, CGSize(width: w, height: h))
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx.makeImage() else {
            return (image, CGSize(width: w, height: h))
        }
        return (resized, CGSize(width: newW, height: newH))
    }
}
