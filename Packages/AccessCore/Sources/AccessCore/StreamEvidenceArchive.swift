import Foundation
import simd

/// A bounded inspection view of saved stream evidence. Opening it never changes upload state.
public struct StreamEvidenceArchive: Sendable {
    public let manifest: StreamManifest
    public let frameCount: Int
    private let root: URL
    private static let maximumManifestBytes = 64 * 1024
    private static let maximumPreviewFrames = 24
    private static let maximumPreviewPoints = 3_750

    /// Read-only source location, used to keep derived exports outside the saved archive.
    public var rootURL: URL { root }

    public init(root: URL, expectedScanID: String) throws {
        try Task.checkCancellation()
        guard root.isFileURL else { throw StreamingCaptureError.storageFailure }
        let data = try Self.readBounded(root.appendingPathComponent("manifest.json"),
                                        maximumBytes: Self.maximumManifestBytes)
        let manifest: StreamManifest
        do { manifest = try JSONDecoder().decode(StreamManifest.self, from: data) }
        catch { throw StreamingCaptureError.invalidManifest }
        try manifest.validate()
        guard manifest.id == expectedScanID else { throw StreamingCaptureError.localConflict }
        self.manifest = manifest
        self.root = root
        self.frameCount = try Self.countChunks(at: root.appendingPathComponent("chunks", isDirectory: true))
    }

    /// Covers the complete walk, including its first and last frames, within a fixed preview budget.
    public func sampledSequences(maximumFrames: Int = 24) -> [Int] {
        let count = min(frameCount, max(0, min(maximumFrames, Self.maximumPreviewFrames)))
        guard count > 0 else { return [] }
        guard count > 1 else { return [0] }
        return (0..<count).map { $0 * (frameCount - 1) / (count - 1) }
    }

    public func readChunk(sequence: Int) throws -> StreamChunk {
        try Task.checkCancellation()
        guard (0..<frameCount).contains(sequence) else { throw StreamingCaptureError.missingChunks }
        let data = try Self.readBounded(Self.chunkURL(root: root, sequence: sequence),
                                        maximumBytes: StreamChunk.maximumEncodedBytes)
        let chunk: StreamChunk
        do { chunk = try JSONDecoder().decode(StreamChunk.self, from: data) }
        catch { throw StreamingCaptureError.invalidChunk }
        guard chunk.sequence == sequence else { throw StreamingCaptureError.invalidChunk }
        try Task.checkCancellation()
        try chunk.validate()
        try Task.checkCancellation()
        return chunk
    }

    /// Projects measured depth into the scan's original coordinates, with sensor-native color UVs.
    public static func points(in frame: CaptureDepthFrame, maximumPoints: Int = 3_750) throws -> [StreamEvidencePoint] {
        try Task.checkCancellation()
        guard frame.depth.valuesM.count <= StreamChunk.maximumDepthSamples else {
            throw StreamingCaptureError.invalidChunk
        }
        try CaptureBundle(id: "evidence", mapID: "evidence", frames: [frame]).validate()
        let limit = max(0, min(maximumPoints, maximumPreviewPoints))
        guard limit > 0, let confidence = frame.depth.confidence else { return [] }
        let values = frame.mapFromCamera
        let transform = simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
        let depth = frame.depth
        let camera = frame.camera
        let step = (depth.valuesM.count - 1) / limit + 1
        var result: [StreamEvidencePoint] = []
        result.reserveCapacity(min(limit, depth.valuesM.count))
        for index in stride(from: 0, to: depth.valuesM.count, by: step) {
            try Task.checkCancellation()
            guard let distance = depth.valuesM[index], distance >= 0.10, distance <= 8,
                  confidence[index] >= 1 else { continue }
            let uv = SIMD2(Float(index % depth.width) / Float(depth.width),
                           Float(index / depth.width) / Float(depth.height))
            let local = SIMD4<Float>(
                (uv.x * Float(camera.imageWidth) - camera.cx) * distance / camera.fx,
                -(uv.y * Float(camera.imageHeight) - camera.cy) * distance / camera.fy,
                -distance, 0
            )
            let rotated = transform * local
            let position = SIMD3(rotated.x, rotated.y, rotated.z) + transform.translation
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            result.append(StreamEvidencePoint(position: position, imageCoordinate: uv))
        }
        return result
    }

    private static func chunkURL(root: URL, sequence: Int) -> URL {
        let number = String(sequence)
        let padded = String(repeating: "0", count: max(0, 10 - number.count)) + number
        return root.appendingPathComponent("chunks", isDirectory: true)
            .appendingPathComponent("chunk-\(padded).json")
    }

    private static func countChunks(at directory: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                  options: [.skipsSubdirectoryDescendants]) else { throw StreamingCaptureError.missingChunks }
        var count = 0
        var maximum = -1
        var totalBytes = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let name = file.lastPathComponent
            guard name.hasPrefix("chunk-"), name.hasSuffix(".json") else { continue }
            let number = name.dropFirst(6).dropLast(5)
            guard let sequence = Int(number), sequence >= 0,
                  sequence < StreamingCaptureLimits.standard.maximumFrames,
                  chunkURL(root: directory.deletingLastPathComponent(), sequence: sequence).lastPathComponent == name else {
                throw StreamingCaptureError.missingChunks
            }
            let size = try checkedSize(file, maximumBytes: StreamChunk.maximumEncodedBytes)
            totalBytes += size
            count += 1
            guard count <= StreamingCaptureLimits.standard.maximumFrames,
                  totalBytes <= StreamingCaptureLimits.standard.maximumSavedBytes else {
                throw StreamingCaptureError.captureLimit
            }
            maximum = max(maximum, sequence)
        }
        guard count == maximum + 1 else { throw StreamingCaptureError.missingChunks }
        return count
    }

    private static func checkedSize(_ url: URL, maximumBytes: Int) throws -> Int {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw StreamingCaptureError.missingChunks }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { throw StreamingCaptureError.missingChunks }
        guard size <= maximumBytes else { throw StreamingCaptureError.chunkTooLarge }
        return size
    }

    /// Limits the actual read as well as the stat, so a changed file cannot allocate without bound.
    private static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data {
        _ = try checkedSize(url, maximumBytes: maximumBytes)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw StreamingCaptureError.storageFailure }
        defer { try? handle.close() }
        var result = Data()
        while true {
            try Task.checkCancellation()
            let chunk: Data
            do { chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes - result.count + 1)) ?? Data() }
            catch { throw StreamingCaptureError.storageFailure }
            guard !chunk.isEmpty else { return result }
            guard chunk.count <= maximumBytes - result.count else { throw StreamingCaptureError.chunkTooLarge }
            result.append(chunk)
        }
    }
}

public struct StreamEvidencePoint: Equatable, Sendable {
    public let position: SIMD3<Float>
    public let imageCoordinate: SIMD2<Float>

    public init(position: SIMD3<Float>, imageCoordinate: SIMD2<Float>) {
        self.position = position
        self.imageCoordinate = imageCoordinate
    }
}
