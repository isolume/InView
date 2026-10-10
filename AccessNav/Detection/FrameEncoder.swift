import CoreImage
import CoreVideo
import ImageIO

/// Turns ARKit camera frames into small upright JPEGs for the vision model.
enum FrameEncoder {
    private static let context = CIContext()

    /// ARKit delivers frames in the sensor's landscape orientation; rotate to portrait to match how the phone is held.
    static func portraitJPEG(from pixelBuffer: CVPixelBuffer, maxDimension: CGFloat = 1024) -> Data? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let scale = maxDimension / max(image.extent.width, image.extent.height)
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
        )
    }

    /// Maps a normalized point in the portrait JPEG back to the captured (landscape) image.
    static func capturedImagePoint(fromPortrait point: CGPoint) -> CGPoint {
        CGPoint(x: point.y, y: 1 - point.x)
    }
}
