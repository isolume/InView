import AccessCore
import CoreGraphics
import Foundation
import ImageIO

/// Colors optional scan detail from paired saved photos and depth. Legacy stream archives
/// are read one chunk at a time; canonical scans use their bounded retained keyframes.
enum MeshColorizer {
    /// Spread over the whole walk. More photos add little once each surface has a few good views.
    static let maximumPhotos = MeshColoring.maximumPhotos
    /// Vertices are a few centimeters apart, so larger photos only cost decoding time.
    static let photoSize = 512

    struct Result: Sendable {
        var mesh: CaptureMesh
        var photos: Int
        var coverage: Float
    }

    /// Nil when no saved photo saw the mesh, or there's no stream to read.
    nonisolated static func color(_ mesh: CaptureMesh, scanID: String) throws -> Result? {
        try Task.checkCancellation()
        guard var coloring = MeshColoring(mesh: mesh) else { return nil }
        let archive = try StreamEvidenceArchive(root: CaptureStore.streamRoot(for: scanID), expectedScanID: scanID)
        let photoLimit = min(maximumPhotos, MeshColoring.photoLimit(vertexCount: mesh.vertices.count))
        for sequence in archive.sequences(spreadOver: photoLimit) {
            try Task.checkCancellation()
            // One unreadable chunk shouldn't leave the whole model grey.
            let chunk: StreamChunk
            do { chunk = try archive.readChunk(sequence: sequence) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            try Task.checkCancellation()
            guard let image = decode(chunk.colorJPEG) else { continue }
            try coloring.add(frame: chunk.frame, image: image)
        }
        guard coloring.observationsUsed > 0 else { return nil }
        var colored = mesh
        colored.colors = try coloring.colors()
        return Result(mesh: colored, photos: coloring.observationsUsed, coverage: coloring.coverage)
    }

    /// Canonical RoomPlan scans retain a bounded set of paired depth and upright photographs.
    /// Their calibration stays sensor-native; only color sampling rotates into the saved image.
    nonisolated static func color(_ mesh: CaptureMesh, frames: [CaptureDepthFrame],
                                  colors keyframes: [RawColorKeyframe]) throws -> Result? {
        try Task.checkCancellation()
        guard frames.count <= 2_000, keyframes.count <= 2_000,
              var coloring = MeshColoring(mesh: mesh) else { return nil }
        let byID = Dictionary(keyframes.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        let pairs = frames.compactMap { frame in byID[frame.id].map { (frame, $0) } }
        let count = min(pairs.count, MeshColoring.photoLimit(vertexCount: mesh.vertices.count))
        guard count > 0 else { return nil }
        let indices = count == 1 ? [0] : (0..<count).map { $0 * (pairs.count - 1) / (count - 1) }
        for index in indices {
            try Task.checkCancellation()
            let (frame, photo) = pairs[index]
            guard let image = decode(photo.jpeg, orientation: .portraitClockwise) else { continue }
            try coloring.add(frame: frame, image: image)
        }
        guard coloring.observationsUsed > 0 else { return nil }
        var colored = mesh
        colored.colors = try coloring.colors()
        return Result(mesh: colored, photos: coloring.observationsUsed, coverage: coloring.coverage)
    }

    private nonisolated static func decode(_ jpeg: Data,
                                          orientation: ColorImage.Orientation = .sensorNative) -> ColorImage? {
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
        return drawn ? ColorImage(width: width, height: height, rgba: pixels, orientation: orientation) : nil
    }
}
