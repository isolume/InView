import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import AccessCore

private let evidenceIdentity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func evidenceFrame() -> CaptureDepthFrame {
    CaptureDepthFrame(id: UUID().uuidString, timestampSeconds: 1, mapFromCamera: evidenceIdentity,
                      camera: CaptureCameraCalibration(imageWidth: 2, imageHeight: 2, fx: 2, fy: 2, cx: 1, cy: 1),
                      depth: CaptureDepthImage(width: 2, height: 2, valuesM: [1, 1, 1, 1], confidence: [2, 2, 2, 2]))
}

private func evidenceJPEG() throws -> Data {
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func evidenceChunkURL(_ root: URL, _ sequence: Int) -> URL {
    root.appendingPathComponent("chunks", isDirectory: true)
        .appendingPathComponent(String(format: "chunk-%010d.json", sequence))
}

private func evidenceArchiveFixture(count: Int) throws -> (URL, StreamManifest) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("inview-evidence-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("chunks"), withIntermediateDirectories: true)
    let manifest = StreamManifest(id: UUID().uuidString, mapID: "building-1", floorID: "ground")
    try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
    let jpeg = try evidenceJPEG()
    for sequence in 0..<count {
        var frame = evidenceFrame()
        frame.timestampSeconds = Double(sequence + 1)
        let chunk = StreamChunk(sequence: sequence, frame: frame, colorJPEG: jpeg)
        try chunk.encoded().write(to: evidenceChunkURL(root, sequence))
    }
    return (root, manifest)
}

@Test func streamEvidenceOpeningAndReadingPreservesUploadCheckpoint() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let checkpoint = root.appendingPathComponent("checkpoint.json")
    let original = Data("{\"backend_url\":\"https://example.invalid\",\"uploaded\":1,\"capture_closed\":true,\"finished\":false}".utf8)
    try original.write(to: checkpoint)
    let originalDate = try checkpoint.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    let manifestBefore = try Data(contentsOf: root.appendingPathComponent("manifest.json"))

    let archive = try StreamEvidenceArchive(root: root, expectedScanID: manifest.id)
    #expect(archive.manifest == manifest)
    #expect(archive.frameCount == 3)
    #expect(archive.sampledSequences() == [0, 1, 2])
    let chunk = try archive.readChunk(sequence: 1)
    #expect(chunk.sequence == 1)
    #expect(try StreamEvidenceArchive.points(in: chunk.frame).count == 4)
    #expect(try Data(contentsOf: checkpoint) == original)
    #expect(try checkpoint.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalDate)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == filesBefore)
    #expect(try Data(contentsOf: root.appendingPathComponent("manifest.json")) == manifestBefore)
}

@Test func streamEvidenceSamplesWholeWalkWithinHardFrameBudget() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 100)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try StreamEvidenceArchive(root: root, expectedScanID: manifest.id)
    let samples = archive.sampledSequences(maximumFrames: Int.max)
    #expect(samples.count == 24)
    #expect(samples.first == 0)
    #expect(samples.last == 99)
    #expect(Set(samples).count == samples.count)
    #expect(zip(samples.dropFirst(), samples).allSatisfy { (4...5).contains($0 - $1) })
    #expect(archive.sampledSequences(maximumFrames: 3) == [0, 49, 99])
    #expect(archive.sampledSequences(maximumFrames: 1) == [0])
    #expect(archive.sampledSequences(maximumFrames: 0).isEmpty)
    #expect(archive.sampledSequences(maximumFrames: -1).isEmpty)
}

@Test func streamEvidenceEmptyArchiveHasNoPreviewSamples() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 0)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try StreamEvidenceArchive(root: root, expectedScanID: manifest.id)
    #expect(archive.frameCount == 0)
    #expect(archive.sampledSequences().isEmpty)
    #expect(throws: StreamingCaptureError.missingChunks) { try archive.readChunk(sequence: 0) }
}

@Test func streamEvidenceRejectsWrongOrCorruptManifest() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: StreamingCaptureError.localConflict) {
        try StreamEvidenceArchive(root: root, expectedScanID: UUID().uuidString)
    }
    var unsupported = manifest
    unsupported.schemaVersion = 999
    try JSONEncoder().encode(unsupported).write(to: root.appendingPathComponent("manifest.json"))
    #expect(throws: StreamingCaptureError.invalidManifest) { try StreamEvidenceArchive(root: root, expectedScanID: manifest.id) }
    try Data("broken".utf8).write(to: root.appendingPathComponent("manifest.json"))
    #expect(throws: StreamingCaptureError.invalidManifest) { try StreamEvidenceArchive(root: root, expectedScanID: manifest.id) }
}

@Test func streamEvidenceRejectsMissingOrNoncanonicalChunks() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let middle = try Data(contentsOf: evidenceChunkURL(root, 1))
    try FileManager.default.removeItem(at: evidenceChunkURL(root, 1))
    #expect(throws: StreamingCaptureError.missingChunks) { try StreamEvidenceArchive(root: root, expectedScanID: manifest.id) }
    try middle.write(to: evidenceChunkURL(root, 1))
    try FileManager.default.moveItem(at: evidenceChunkURL(root, 0),
                                    to: root.appendingPathComponent("chunks/chunk-0.json"))
    #expect(throws: StreamingCaptureError.missingChunks) { try StreamEvidenceArchive(root: root, expectedScanID: manifest.id) }
}

@Test func streamEvidenceReadValidatesChangedChunkSizeSequenceAndImage() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try StreamEvidenceArchive(root: root, expectedScanID: manifest.id)
    let url = evidenceChunkURL(root, 0)
    let original = try Data(contentsOf: url)
    try Data("broken".utf8).write(to: url)
    #expect(throws: StreamingCaptureError.invalidChunk) { try archive.readChunk(sequence: 0) }
    var wrong = try JSONDecoder().decode(StreamChunk.self, from: original)
    wrong.sequence = 4
    try JSONEncoder().encode(wrong).write(to: url)
    #expect(throws: StreamingCaptureError.invalidChunk) { try archive.readChunk(sequence: 0) }
    wrong.sequence = 0
    wrong.colorJPEG = Data([0xff, 0xd8, 0xff, 0xd9])
    try JSONEncoder().encode(wrong).write(to: url)
    #expect(throws: StreamingCaptureError.invalidChunk) { try archive.readChunk(sequence: 0) }
    try Data(repeating: 0, count: StreamChunk.maximumEncodedBytes + 1).write(to: url)
    #expect(throws: StreamingCaptureError.chunkTooLarge) { try archive.readChunk(sequence: 0) }
    #expect(throws: StreamingCaptureError.chunkTooLarge) { try StreamEvidenceArchive(root: root, expectedScanID: manifest.id) }
    try FileManager.default.removeItem(at: url)
    #expect(throws: StreamingCaptureError.missingChunks) { try archive.readChunk(sequence: 0) }
    #expect(throws: StreamingCaptureError.missingChunks) { try archive.readChunk(sequence: -1) }
    #expect(throws: StreamingCaptureError.missingChunks) { try archive.readChunk(sequence: 1) }
}

@Test func streamEvidenceRejectsSymlinkChunks() throws {
    let (root, manifest) = try evidenceArchiveFixture(count: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = evidenceChunkURL(root, 0)
    let sidecar = root.appendingPathComponent("original.json")
    try FileManager.default.moveItem(at: original, to: sidecar)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: sidecar)
    #expect(throws: StreamingCaptureError.missingChunks) { try StreamEvidenceArchive(root: root, expectedScanID: manifest.id) }
}

@Test func streamEvidenceProjectsScaledCalibrationThroughRotationAndTranslation() throws {
    var frame = evidenceFrame()
    frame.camera = CaptureCameraCalibration(imageWidth: 4, imageHeight: 4, fx: 4, fy: 4, cx: 2, cy: 2)
    frame.mapFromCamera = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 10, 20, 30, 1]
    let points = try StreamEvidenceArchive.points(in: frame)
    #expect(points.map(\.position) == [SIMD3(9, 20.5, 30.5), SIMD3(9, 20.5, 30), SIMD3(9, 20, 30.5), SIMD3(9, 20, 30)])
    #expect(points.map(\.imageCoordinate) == [SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(0, 0.5), SIMD2(0.5, 0.5)])
}

@Test func streamEvidenceExcludesMissingUncertainAndOutOfRangeDepth() throws {
    var frame = evidenceFrame()
    frame.camera = CaptureCameraCalibration(imageWidth: 4, imageHeight: 2, fx: 4, fy: 2, cx: 2, cy: 1)
    frame.depth = CaptureDepthImage(width: 4, height: 2, valuesM: [nil, 0.09, 0.10, 8, 8.1, 0, 1, 1],
                                   confidence: [2, 2, 2, 2, 2, 2, 0, 1])
    let points = try StreamEvidenceArchive.points(in: frame)
    #expect(points.count == 3)
    #expect(points.map(\.position.z) == [-0.10, -8, -1])
    frame.depth.confidence = nil
    #expect(try StreamEvidenceArchive.points(in: frame).isEmpty)
}

@Test func streamEvidenceHasHardPointBudgetAndValidatesProjectionInput() throws {
    var frame = evidenceFrame()
    frame.camera = CaptureCameraCalibration(imageWidth: 256, imageHeight: 256, fx: 256, fy: 256, cx: 128, cy: 128)
    frame.depth = CaptureDepthImage(width: 256, height: 256,
                                   valuesM: [Float?](repeating: 1, count: 256 * 256),
                                   confidence: [Int](repeating: 2, count: 256 * 256))
    let points = try StreamEvidenceArchive.points(in: frame, maximumPoints: Int.max)
    #expect(!points.isEmpty)
    #expect(points.count <= 3_750)
    #expect(try StreamEvidenceArchive.points(in: frame, maximumPoints: 100).count <= 100)
    #expect(try StreamEvidenceArchive.points(in: frame, maximumPoints: 0).isEmpty)
    frame.mapFromCamera = []
    #expect(throws: CaptureValidationError.self) { try StreamEvidenceArchive.points(in: frame) }
    frame = evidenceFrame()
    frame.camera.fx = 0
    #expect(throws: CaptureValidationError.self) { try StreamEvidenceArchive.points(in: frame) }
}

@Test func streamEvidenceProjectionHonorsCancellation() async throws {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try StreamEvidenceArchive.points(in: evidenceFrame())
            return false
        } catch is CancellationError { return true }
    }
    #expect(try await task.value)
}
