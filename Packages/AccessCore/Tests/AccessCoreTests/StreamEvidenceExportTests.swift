import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AccessCore

private let exportIdentity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private struct ExportFixture {
    let directory: URL
    let source: URL
    let manifest: StreamManifest
    let jpeg: Data
    var destination: URL { directory.appendingPathComponent("scan-data.tar") }
    var archive: StreamEvidenceArchive { get throws { try StreamEvidenceArchive(root: source, expectedScanID: manifest.id) } }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func chunkURL(_ sequence: Int) -> URL {
        source.appendingPathComponent("chunks/" + String(format: "chunk-%010d.json", sequence))
    }
}

private func exportFixture(count: Int, depthSize: Int = 2) throws -> ExportFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inview-export-test-\(UUID().uuidString)")
    let source = directory.appendingPathComponent("stream")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("chunks"), withIntermediateDirectories: true)
    let manifest = StreamManifest(id: UUID().uuidString, mapID: "building", floorID: "second")
    try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
    try Data("{\"uploaded\":1,\"capture_closed\":true,\"finished\":false}".utf8)
        .write(to: source.appendingPathComponent("upload.json"))
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let jpeg = encoded as Data
    let fixture = ExportFixture(directory: directory, source: source, manifest: manifest, jpeg: jpeg)
    for sequence in 0..<count {
        var pose = exportIdentity
        pose[12] = Float(sequence) * 0.25
        let values: [Float?] = depthSize == 2 ? [1.25, nil, 0, 8] : Array(repeating: 1.25, count: depthSize * depthSize)
        let confidence = depthSize == 2 ? [2, 1, 0, 2] : Array(repeating: 2, count: values.count)
        let frame = CaptureDepthFrame(id: "frame/\(sequence)", timestampSeconds: Double(sequence) + 0.125,
                                      mapFromCamera: pose,
                                      camera: CaptureCameraCalibration(imageWidth: 2, imageHeight: 2, fx: 2.5, fy: 2.75, cx: 0.75, cy: 1.25),
                                      depth: CaptureDepthImage(width: depthSize, height: depthSize, valuesM: values, confidence: confidence))
        let objects = sequence == 0
            ? [CaptureObject(id: "table-original", category: "table", confidence: .medium,
                             mapFromObject: exportIdentity, dimensionsM: [1, 0.7, 1])]
            : []
        let surfaces = sequence == 0
            ? [CaptureSurface(id: "floor-original", kind: "floor", mapFromSurface: exportIdentity,
                              dimensionsM: [4, 0.01, 4], polygonCorners: [[-2, 0, -2], [2, 0, -2], [2, 0, 2], [-2, 0, 2]])]
            : []
        let chunk = StreamChunk(sequence: sequence, frame: frame, colorJPEG: jpeg, surfaces: surfaces, objects: objects)
        try chunk.encoded().write(to: fixture.chunkURL(sequence))
    }
    return fixture
}

private func sourceBytes(_ directory: URL) throws -> [String: Data] {
    let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: Data] = [:]
    for case let file as URL in enumerator {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: file)
        }
    }
    return result
}

private func temporaryExports(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".inview-export-") }
}

/// An independent minimal TAR decoder verifies alignment, checksums, lengths, and safe paths.
private func exportedFiles(_ url: URL) throws -> [String: Data] {
    let tar = try Data(contentsOf: url)
    var result: [String: Data] = [:]
    var offset = 0
    while offset + 512 <= tar.count {
        let header = Array(tar[offset..<(offset + 512)])
        if header.allSatisfy({ $0 == 0 }) {
            #expect(tar.count - offset >= 1024)
            #expect(tar[offset...].allSatisfy { $0 == 0 })
            return result
        }
        func string(_ range: Range<Int>) -> String {
            String(decoding: header[range].prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
        let name = string(0..<100)
        #expect(!name.hasPrefix("/"))
        #expect(!name.split(separator: "/").contains(".."))
        #expect(header[156] == UInt8(ascii: "0"))
        #expect(string(257..<263) == "ustar")
        let size = try #require(Int(string(124..<136), radix: 8))
        let checksum = try #require(Int(string(148..<156), radix: 8))
        var sum = 0
        for index in header.indices { sum += (148..<156).contains(index) ? 32 : Int(header[index]) }
        #expect(sum == checksum)
        #expect(result[name] == nil)
        let start = offset + 512
        guard size >= 0, start + size <= tar.count else { throw StreamingCaptureError.storageFailure }
        result[name] = Data(tar[start..<(start + size)])
        offset = start + size + ((512 - size % 512) % 512)
    }
    throw StreamingCaptureError.storageFailure
}

private struct ExportAssetRecord: Decodable {
    var path: String
    var role: String
    var bytes: UInt64
}
private struct ExportObservationRecord: Decodable {
    struct Depth: Decodable {
        var asset: ExportAssetRecord
        var width: Int
        var height: Int
        var bytesPerRow: Int
        enum CodingKeys: String, CodingKey { case asset, width, height, bytesPerRow = "bytes_per_row" }
    }
    struct Confidence: Decodable {
        var asset: ExportAssetRecord
        var bytesPerRow: Int
        enum CodingKeys: String, CodingKey { case asset, bytesPerRow = "bytes_per_row" }
    }
    var sequence: Int
    var id: String
    var timestampSeconds: Double
    var pixelOrientation: String
    var mapFromCamera: [Float]
    var camera: CaptureCameraCalibration
    var depth: Depth
    var confidence: Confidence?
    var rgb: ExportAssetRecord
    var objects: [CaptureObject]
    var surfaces: [CaptureSurface]
    enum CodingKeys: String, CodingKey {
        case sequence, id, timestampSeconds = "timestamp_seconds", pixelOrientation = "pixel_orientation"
        case mapFromCamera = "map_from_camera", camera, depth, confidence, rgb, objects, surfaces
    }
}
private func observations(_ files: [String: Data]) throws -> [ExportObservationRecord] {
    let data = try #require(files["observations.jsonl"])
    return try data.split(separator: 0x0a).map { try JSONDecoder().decode(ExportObservationRecord.self, from: Data($0)) }
}

@Test func streamEvidenceExportRoundTripsDepthConfidenceRGBAndCalibration() throws {
    let fixture = try exportFixture(count: 2)
    defer { fixture.remove() }
    let before = try sourceBytes(fixture.source)
    let checkpoint = fixture.source.appendingPathComponent("upload.json")
    let checkpointDate = try checkpoint.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let archive = try fixture.archive
    try StreamEvidenceExport.write(archive: archive, to: fixture.destination)
    let files = try exportedFiles(fixture.destination)
    let records = try observations(files)
    #expect(records.count == 2)
    for record in records {
        let original = try archive.readChunk(sequence: record.sequence)
        #expect(record.id == original.frame.id)
        #expect(record.timestampSeconds == original.frame.timestampSeconds)
        #expect(record.pixelOrientation == "sensor_native")
        #expect(record.mapFromCamera == original.frame.mapFromCamera)
        #expect(record.camera == original.frame.camera)
        #expect(record.objects == original.objects)
        #expect(record.surfaces == original.surfaces)
        #expect(files[record.rgb.path] == fixture.jpeg)
        #expect(record.rgb.role == "rgb_keyframe")
        #expect(record.rgb.bytes == UInt64(fixture.jpeg.count))
        #expect(record.depth.width == 2 && record.depth.height == 2 && record.depth.bytesPerRow == 8)
        #expect(record.depth.asset.role == "packed_portable_depth")
        let depth = try #require(files[record.depth.asset.path])
        #expect(record.depth.asset.bytes == 16)
        let words: [UInt32] = stride(from: 0, to: depth.count, by: 4).map { index in
            UInt32(depth[index]) | UInt32(depth[index + 1]) << 8 | UInt32(depth[index + 2]) << 16 | UInt32(depth[index + 3]) << 24
        }
        #expect(words == [Float(1.25).bitPattern, 0x7fc00000, Float(0).bitPattern, Float(8).bitPattern])
        #expect(Float(bitPattern: words[1]).isNaN)
        let confidence = try #require(record.confidence)
        #expect(confidence.bytesPerRow == 2)
        #expect(confidence.asset.bytes == 4)
        #expect(files[confidence.asset.path] == Data([2, 1, 0, 2]))
        #expect(!record.rgb.path.contains(record.id))
    }
    let manifestData = try #require(files["manifest.json"])
    let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    #expect(manifest["schema_version"] as? Int == 1)
    #expect(manifest["format"] as? String == "inview_stream_evidence")
    #expect(manifest["frame_count"] as? Int == 2)
    #expect(manifest["depth_provenance"] as? String == "Saved portable depth values, not byte-exact native ARKit buffers. Original row padding and discarded invalid samples are unavailable.")
    let source = try #require(manifest["source"] as? [String: Any])
    #expect(source["id"] as? String == fixture.manifest.id)
    #expect(source["map_id"] as? String == "building")
    #expect(source["floor_id"] as? String == "second")
    let index = try #require(manifest["observations"] as? [String: Any])
    #expect(index["bytes"] as? Int == files["observations.jsonl"]?.count)
    #expect(try sourceBytes(fixture.source) == before)
    #expect(try checkpoint.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == checkpointDate)
    #expect(try temporaryExports(fixture.directory).isEmpty)
}

@Test func streamEvidenceExportIncludesWholeWalkBeyondPreviewBudget() throws {
    let fixture = try exportFixture(count: 100)
    defer { fixture.remove() }
    let archive = try fixture.archive
    #expect(archive.sampledSequences().count == 24)
    try StreamEvidenceExport.write(archive: archive, to: fixture.destination)
    let files = try exportedFiles(fixture.destination)
    let records = try observations(files)
    #expect(records.map(\.sequence) == Array(0..<100))
    #expect(records.map(\.id) == (0..<100).map { "frame/\($0)" })
    #expect(files.count == 302)
}

@Test func streamEvidenceExportPreservesExistingDestination() throws {
    let fixture = try exportFixture(count: 1)
    defer { fixture.remove() }
    let existing = Data("keep this existing file".utf8)
    try existing.write(to: fixture.destination)
    #expect(throws: StreamEvidenceExportError.destinationExists) {
        try StreamEvidenceExport.write(archive: fixture.archive, to: fixture.destination)
    }
    #expect(try Data(contentsOf: fixture.destination) == existing)
    #expect(try temporaryExports(fixture.directory).isEmpty)
}

@Test func streamEvidenceExportRejectsSourceDestinationAndSymlinkAlias() throws {
    let fixture = try exportFixture(count: 1)
    defer { fixture.remove() }
    let before = try sourceBytes(fixture.source)
    let alias = fixture.directory.appendingPathComponent("source-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
    let archive = try fixture.archive
    for destination in [fixture.source.appendingPathComponent("scan.tar"), alias.appendingPathComponent("scan.tar"),
                        fixture.source.appendingPathComponent("chunks/scan.tar")] {
        #expect(throws: StreamEvidenceExportError.invalidDestination) {
            try StreamEvidenceExport.write(archive: archive, to: destination)
        }
    }
    #expect(try sourceBytes(fixture.source) == before)
    #expect(try temporaryExports(fixture.directory).isEmpty)
}

@Test func streamEvidenceExportCleansPartialFilesOnInvalidLaterChunk() throws {
    let fixture = try exportFixture(count: 3)
    defer { fixture.remove() }
    let archive = try fixture.archive
    try Data("broken".utf8).write(to: fixture.chunkURL(1))
    let before = try sourceBytes(fixture.source)
    #expect(throws: StreamingCaptureError.invalidChunk) {
        try StreamEvidenceExport.write(archive: archive, to: fixture.destination)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(try temporaryExports(fixture.directory).isEmpty)
    #expect(try sourceBytes(fixture.source) == before)
}

@Test func streamEvidenceExportHonorsCancellationBeforeWriting() async throws {
    let fixture = try exportFixture(count: 1)
    defer { fixture.remove() }
    let archive = try fixture.archive
    let destination = fixture.destination
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            try StreamEvidenceExport.write(archive: archive, to: destination)
            return false
        } catch is CancellationError { return true }
    }
    #expect(try await task.value)
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(try temporaryExports(fixture.directory).isEmpty)
}

@Test func streamEvidenceExportCleansPartialFilesWhenCancelledDuringWriting() async throws {
    let fixture = try exportFixture(count: 200, depthSize: 64)
    defer { fixture.remove() }
    let archive = try fixture.archive
    let before = try sourceBytes(fixture.source)
    let destination = fixture.destination
    let task = Task.detached { try StreamEvidenceExport.write(archive: archive, to: destination) }
    let deadline = Date().addingTimeInterval(5)
    var observedPartial = false
    while Date() < deadline {
        if !(try temporaryExports(fixture.directory)).isEmpty {
            observedPartial = true
            break
        }
        try await Task.sleep(nanoseconds: 500_000)
    }
    task.cancel()
    #expect(observedPartial)
    do {
        try await task.value
        Issue.record("Expected cancellation before publication")
    } catch is CancellationError { }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(try temporaryExports(fixture.directory).isEmpty)
    #expect(try sourceBytes(fixture.source) == before)
}

@Test func streamEvidenceExportCanRepresentEmptySavedEvidence() throws {
    let fixture = try exportFixture(count: 0)
    defer { fixture.remove() }
    try StreamEvidenceExport.write(archive: fixture.archive, to: fixture.destination)
    let files = try exportedFiles(fixture.destination)
    #expect(files.count == 2)
    #expect(files["observations.jsonl"]?.isEmpty == true)
    #expect(try observations(files).isEmpty)
}

#if os(macOS)
@Test func streamEvidenceExportIsReadableBySystemTar() throws {
    let fixture = try exportFixture(count: 2)
    defer { fixture.remove() }
    try StreamEvidenceExport.write(archive: fixture.archive, to: fixture.destination)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-tf", fixture.destination.path]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(errors.isEmpty)
    #expect(Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
            == Set(try exportedFiles(fixture.destination).keys))
}
#endif
