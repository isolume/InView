import CoreImage
import CoreVideo
import ImageIO

/// Turns ARKit camera frames into small upright JPEGs for the vision model, without keeping ARKit's buffers.
///
/// ARKit recycles a small pool of camera buffers; holding one across a network round trip starves tracking.
/// So a frame's pixels are copied out synchronously (`snapshot`), and the slow part, scaling and JPEG
/// encoding, runs on the copy off the main thread.
enum FrameEncoder {
    /// A frame's pixels, copied out of ARKit's pool. Nothing else references the copy, so another thread may use it.
    struct Snapshot: @unchecked Sendable {
        fileprivate let pixelBuffer: CVPixelBuffer
    }

    /// The frame as sent to the model, and a smaller copy kept as the find's evidence photo.
    struct Encoded: Sendable {
        let jpeg: Data
        let preview: Data
    }

    /// Longest side of the frame sent to the model. Larger frames cost encode time and upload for little gain.
    static let modelDimension: CGFloat = 1024
    /// Longest side of the evidence photo shown in review.
    static let previewDimension: CGFloat = 600

    /// Renders on the CPU: ARKit and RoomPlan already saturate the GPU, and a Core Image pass on top of
    /// them is what left the camera view without drawables.
    private static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    /// Copies the frame's pixels; a millisecond or two, meant to be called synchronously on the frame.
    static func snapshot(_ source: CVPixelBuffer) -> Snapshot? {
        var copy: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attributes,
            &copy
        )
        guard status == kCVReturnSuccess, let copy else { return nil }
        // Color space and YCbCr matrix tags, so the copy decodes to the same colors.
        CVBufferPropagateAttachments(source, copy)

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                guard copyRows(
                    from: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                    stride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    to: CVPixelBufferGetBaseAddressOfPlane(copy, plane),
                    stride: CVPixelBufferGetBytesPerRowOfPlane(copy, plane),
                    rows: CVPixelBufferGetHeightOfPlane(source, plane)
                ) else { return nil }
            }
        } else {
            guard copyRows(
                from: CVPixelBufferGetBaseAddress(source),
                stride: CVPixelBufferGetBytesPerRow(source),
                to: CVPixelBufferGetBaseAddress(copy),
                stride: CVPixelBufferGetBytesPerRow(copy),
                rows: CVPixelBufferGetHeight(source)
            ) else { return nil }
        }
        return Snapshot(pixelBuffer: copy)
    }

    /// The model's frame plus the evidence preview. Tens of milliseconds; run it off the main thread.
    static func encode(_ snapshot: Snapshot) -> Encoded? {
        let image = portrait(snapshot)
        guard let jpeg = encodeJPEG(image, maxDimension: modelDimension), let preview = encodeJPEG(image, maxDimension: previewDimension) else { return nil }
        return Encoded(jpeg: jpeg, preview: preview)
    }

    /// One upright JPEG of the frame. Tens of milliseconds; run it off the main thread.
    static func portraitJPEG(from snapshot: Snapshot, maxDimension: CGFloat) -> Data? {
        encodeJPEG(portrait(snapshot), maxDimension: maxDimension)
    }

    /// Maps a normalized point in the portrait JPEG back to the captured (landscape) image.
    static func capturedImagePoint(fromPortrait point: CGPoint) -> CGPoint {
        CGPoint(x: point.y, y: 1 - point.x)
    }

    /// ARKit delivers frames in the sensor's landscape orientation; rotate to portrait to match how the phone is held.
    private static func portrait(_ snapshot: Snapshot) -> CIImage {
        CIImage(cvPixelBuffer: snapshot.pixelBuffer).oriented(.right)
    }

    private static func encodeJPEG(_ source: CIImage, maxDimension: CGFloat) -> Data? {
        var image = source
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

    private static func copyRows(
        from source: UnsafeMutableRawPointer?,
        stride sourceStride: Int,
        to destination: UnsafeMutableRawPointer?,
        stride destinationStride: Int,
        rows: Int
    ) -> Bool {
        guard let source, let destination else { return false }
        if sourceStride == destinationStride {
            memcpy(destination, source, rows * sourceStride)
        } else {
            let bytes = min(sourceStride, destinationStride)
            for row in 0..<rows {
                memcpy(destination + row * destinationStride, source + row * sourceStride, bytes)
            }
        }
        return true
    }
}
