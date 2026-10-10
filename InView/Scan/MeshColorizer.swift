import AccessCore
import CoreGraphics
import Foundation
import ImageIO

/// Colors the scan's welded mesh from the photos and depth a continuous scan saved, like a 3D
/// scanning app's colored model. Reads one saved chunk at a time; nothing is uploaded.
enum MeshColorizer {
    /// Spread over the whole walk. More photos add little once each surface has a few good views.
    static let maximumPhotos = 200
    /// Vertices are a few centimeters apart, so larger photos only cost decoding time.
    static let photoSize = 512

    struct Result: Sendable {
        var mesh: CaptureMesh
        var photos: Int
        var coverage: Float
    }

    /// Nil when no saved photo saw the mesh, or there's no stream to read.
    nonisolated static func color(_ mesh: CaptureMesh, scanID: String) throws -> Result? {
        guard var coloring = MeshColoring(mesh: mesh) else { return nil }
        let archive = try StreamEvidenceArchive(root: CaptureStore.streamRoot(for: scanID), expectedScanID: scanID)
        for sequence in archive.sequences(spreadOver: maximumPhotos) {
            try Task.checkCancellation()
            // One unreadable chunk shouldn't leave the whole model grey.
            guard let chunk = try? archive.readChunk(sequence: sequence),
                  let image = decode(chunk.colorJPEG) else { continue }
            try coloring.add(frame: chunk.frame, image: image)
        }
        guard coloring.observationsUsed > 0 else { return nil }
        var colored = mesh
        colored.colors = coloring.colors()
        return Result(mesh: colored, photos: coloring.observationsUsed, coverage: coloring.coverage)
    }

    /// The photo as RGBA rows, kept in the sensor's orientation so it matches the saved calibration.
    private nonisolated static func decode(_ jpeg: Data) -> ColorImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: photoSize,
                  kCGImageSourceCreateThumbnailWithTransform: false,
              ] as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ColorImage(width: width, height: height, rgba: pixels) : nil
    }
}
