import Foundation
import Testing
@testable import AccessCore

private let videoExportIdentity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private struct VideoExportFixture {
    let directory: URL
    let source: URL
    let manifest: ScanVideoManifest
    var destination: URL { directory.appendingPathComponent("reconstruction.tar") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func file(_ name: String) -> URL { source.appendingPathComponent(name) }
    func writeManifest(_ value: ScanVideoManifest) throws {
        try JSONEncoder().encode(value).write(to: file("video-manifest.json"))
    }
}

private func videoExportFixture(segmentCount: Int = 2, videoBytes: Int? = nil) throws -> VideoExportFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inview-video-export-test-\(UUID().uuidString)")
    let source = directory.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let id = UUID().uuidString
    let capture = CaptureBundle(id: id, mapID: "building", floorID: "second",
                                meshes: [CaptureMesh(id: "measured", mapFromAnchor: videoExportIdentity,
                                                     vertices: [[0, 0, 0], [2, 0, 0], [0, 0, 3]],
                                                     triangles: [[0, 1, 2]])])
    try JSONEncoder().encode(capture).write(to: source.appendingPathComponent("capture.json"))
    var segments: [ScanVideoSegment] = []
    for index in 0..<segmentCount {
        let segmentID = ScanVideoSegment.identifier(index: index)
        let sensor = CaptureCameraCalibration(imageWidth: 4, imageHeight: 2, fx: 4, fy: 4, cx: 2, cy: 1)
        let encoded = CaptureCameraCalibration(imageWidth: 2, imageHeight: 1, fx: 2, fy: 2, cx: 1, cy: 0.5)
        let start = Double(index) + 100
        let frames = [0.0, 0.37].enumerated().map { frameIndex, elapsed in
            ScanVideoFrame(index: frameIndex, timestampSeconds: start + elapsed,
                           presentationTimeSeconds: elapsed, mapFromCamera: videoExportIdentity,
                           sensorCamera: sensor, videoCamera: encoded, tracking: "normal", mapping: "mapped",
                           rawDepth: ScanVideoDepth(width: 2, height: 1, bytesPerRow: 12,
                                                    offset: frameIndex * 16, length: 12,
                                                    confidenceOffset: frameIndex * 16 + 12,
                                                    confidenceLength: 4, confidenceBytesPerRow: 4))
        }
        let document = ScanVideoFrameDocument(segmentID: segmentID, videoAsset: segmentID + ".mp4",
                                              depthAsset: segmentID + ".depth.bin", videoWidth: 2,
                                              videoHeight: 1, frames: frames)
        let frameData = try JSONEncoder().encode(document)
        // Preserve native padding and a NaN raw bit pattern, rather than repacking values.
        let row = Data([0, 0, 128, 63, 1, 0, 192, 127, 0xaa, 0xbb, 0xcc, 0xdd, 2, 0, 0xee, 0xff])
        let depth = row + row
        let video = Data("saved mp4 \(segmentID)".utf8)
        let mediaURL = source.appendingPathComponent(segmentID + ".mp4")
        try video.write(to: mediaURL)
        if let videoBytes {
            let handle = try FileHandle(forWritingTo: mediaURL)
            try handle.truncate(atOffset: UInt64(videoBytes))
            try handle.close()
        }
        try depth.write(to: source.appendingPathComponent(segmentID + ".depth.bin"))
        try frameData.write(to: source.appendingPathComponent(segmentID + ".frames.json"))
        segments.append(ScanVideoSegment(id: segmentID, videoAsset: segmentID + ".mp4",
                                         depthAsset: segmentID + ".depth.bin", framesAsset: segmentID + ".frames.json",
                                         videoBytes: videoBytes ?? video.count, depthBytes: depth.count,
                                         framesBytes: frameData.count, frameCount: frames.count,
                                         startTimestampSeconds: start, endTimestampSeconds: start + 0.37))
    }
    let manifest = ScanVideoManifest(captureID: id, mapID: "building", floorID: "second",
                                     unixOffsetSeconds: 1_700_000_000,
                                     status: segmentCount > 0 ? "complete" : "partial",
                                     stopReason: segmentCount > 0 ? nil : "No usable video frames were saved.",
                                     segments: segments)
    let fixture = VideoExportFixture(directory: directory, source: source, manifest: manifest)
    try fixture.writeManifest(manifest)
    return fixture
}

private struct VideoTarEntry {
    let offset: UInt64
    let bytes: UInt64
}

/// Inspect headers and skip payloads through a file descriptor, including large exports.
private func videoTarEntries(_ url: URL) throws -> [String: VideoTarEntry] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    var result: [String: VideoTarEntry] = [:]
    var offset: UInt64 = 0
    while offset + 512 <= UInt64(size) {
        try handle.seek(toOffset: offset)
        let data = try #require(try handle.read(upToCount: 512))
        let header = Array(data)
        #expect(header.count == 512)
        if header.allSatisfy({ $0 == 0 }) {
            #expect(offset + 1024 == UInt64(size))
            #expect(try handle.read(upToCount: 512) == Data(repeating: 0, count: 512))
            return result
        }
        func text(_ range: Range<Int>) -> String {
            String(decoding: header[range].prefix(while: { $0 != 0 }), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
        let name = text(0..<100)
        let count = try #require(UInt64(text(124..<136), radix: 8))
        let checksum = try #require(UInt64(text(148..<156), radix: 8))
        let sum = header.indices.reduce(UInt64(0)) { $0 + UInt64((148..<156).contains($1) ? 32 : header[$1]) }
        #expect(checksum == sum)
        #expect(text(257..<263) == "ustar")
        #expect(header[156] == UInt8(ascii: "0"))
        #expect(!name.hasPrefix("/") && !name.split(separator: "/").contains(".."))
        #expect(result[name] == nil)
        #expect(offset + 512 + count <= UInt64(size))
        result[name] = VideoTarEntry(offset: offset + 512, bytes: count)
        offset += 512 + count + ((512 - count % 512) % 512)
    }
    throw ScanVideoExportError.invalidSource
}

private func videoTarData(_ url: URL, entry: VideoTarEntry) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: entry.offset)
    return try #require(try handle.read(upToCount: Int(entry.bytes)))
}

private func videoExportTemporaryFiles(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".inview-video-export-") }
}

@Test func scanVideoExportPreservesAllIndexedMediaAndOriginalMeasuredEvidence() throws {
    let fixture = try videoExportFixture()
    defer { fixture.remove() }
    let optional = ["roomplan.json", "roomplan-structure.json", "camera-track.json", "semantics.json", "worldmap.archive"]
    for name in optional { try Data("original \(name)".utf8).write(to: fixture.file(name)) }
    try Data("unfinished segment excluded".utf8).write(to: fixture.file("video-0002.mp4"))
    try Data("private file excluded".utf8).write(to: fixture.file("unrelated.txt"))
    let names = ["capture.json", "video-manifest.json"] + fixture.manifest.segments.flatMap {
        [$0.videoAsset, $0.depthAsset, $0.framesAsset]
    } + optional
    let original = try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: fixture.file($0))) })
    try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    let entries = try videoTarEntries(fixture.destination)
    let prefix = fixture.manifest.captureID + "/"
    #expect(Set(entries.keys) == Set((names + ["README.txt"]).map { prefix + $0 }))
    for name in names {
        let entry = try #require(entries[prefix + name])
        #expect(try videoTarData(fixture.destination, entry: entry) == original[name])
        #expect(try Data(contentsOf: fixture.file(name)) == original[name])
    }
    let readme = String(decoding: try videoTarData(fixture.destination, entry: #require(entries[prefix + "README.txt"])), as: UTF8.self)
    #expect(readme.contains("same ARFrame") && readme.contains("sensor-native") && readme.contains("scaled"))
    #expect(readme.contains("Do not infer pose") && readme.contains("measurement error"))
    #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
}

@Test func scanVideoExportKeepsCompletedSegmentsAndReasonFromPartialRecording() throws {
    let fixture = try videoExportFixture(segmentCount: 1)
    defer { fixture.remove() }
    var manifest = fixture.manifest
    manifest.status = "partial"
    manifest.stopReason = "Recording stopped because storage was full."
    manifest.skippedSamples = 3
    try fixture.writeManifest(manifest)
    try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    let entries = try videoTarEntries(fixture.destination)
    let entry = try #require(entries[manifest.captureID + "/video-manifest.json"])
    let saved = try JSONDecoder().decode(ScanVideoManifest.self, from: videoTarData(fixture.destination, entry: entry))
    #expect(saved == manifest)
    #expect(saved.segments.count == 1 && saved.stopReason == manifest.stopReason && saved.skippedSamples == 3)
}

@Test func scanVideoExportRejectsRecordingAndEmptyEvidence() throws {
    for count in [0, 1] {
        let fixture = try videoExportFixture(segmentCount: count)
        defer { fixture.remove() }
        var manifest = fixture.manifest
        if count > 0 { manifest.status = "recording" }
        try fixture.writeManifest(manifest)
        #expect(throws: ScanVideoExportError.unfinishedRecording) {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
    }
}

@Test func scanVideoExportRejectsMismatchedScanIdentity() throws {
    let fixture = try videoExportFixture(segmentCount: 1)
    defer { fixture.remove() }
    for key in ["id", "map_id", "floor_id", "coordinates"] {
        let original = try Data(contentsOf: fixture.file("capture.json"))
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        if key == "coordinates" { json[key] = ["units": "feet", "up_axis": "y", "handedness": "right"] }
        else { json[key] = "different" }
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.file("capture.json"))
        #expect(throws: (any Error).self) {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try original.write(to: fixture.file("capture.json"))
    }
}

@Test func scanVideoExportRejectsMissingWrongSizedAndInvalidIndexedAssets() throws {
    let fixture = try videoExportFixture()
    defer { fixture.remove() }
    let segment = try #require(fixture.manifest.segments.last)
    for name in [segment.videoAsset, segment.depthAsset, segment.framesAsset] {
        let asset = fixture.file(name)
        let original = try Data(contentsOf: asset)
        try FileManager.default.removeItem(at: asset)
        #expect(throws: ScanVideoExportError.invalidSource) {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
        }
        try (original + Data([0])).write(to: asset)
        #expect(throws: ScanVideoExportError.invalidSource) {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
        }
        try original.write(to: asset)
    }
    var document = try JSONDecoder().decode(ScanVideoFrameDocument.self, from: Data(contentsOf: fixture.file(segment.framesAsset)))
    document.frames[1].rawDepth.offset = 0
    let broken = try JSONEncoder().encode(document)
    try broken.write(to: fixture.file(segment.framesAsset))
    var manifest = fixture.manifest
    manifest.segments[1].framesBytes = broken.count
    try fixture.writeManifest(manifest)
    #expect(throws: (any Error).self) {
        try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
}

@Test func scanVideoExportRefusesSymlinksAndSpecialFilesEvenForOptionalEvidence() throws {
    let fixture = try videoExportFixture(segmentCount: 1)
    defer { fixture.remove() }
    let outside = fixture.directory.appendingPathComponent("outside.bin")
    try Data("outside evidence".utf8).write(to: outside)
    for name in ["video-manifest.json", "capture.json", "video-0000.mp4", "video-0000.depth.bin", "video-0000.frames.json", "worldmap.archive"] {
        let url = fixture.file(name)
        let original = try? Data(contentsOf: url)
        if original != nil { try FileManager.default.removeItem(at: url) }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        #expect(throws: ScanVideoExportError.invalidSource) {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
        }
        try FileManager.default.removeItem(at: url)
        if let original { try original.write(to: url) }
    }
    try FileManager.default.createDirectory(at: fixture.file("worldmap.archive"), withIntermediateDirectories: false)
    #expect(throws: ScanVideoExportError.invalidSource) {
        try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
}

@Test func scanVideoExportPreservesDestinationAndRejectsSourceAliases() throws {
    let fixture = try videoExportFixture(segmentCount: 1)
    defer { fixture.remove() }
    let existing = Data("existing destination".utf8)
    try existing.write(to: fixture.destination)
    #expect(throws: ScanVideoExportError.destinationExists) {
        try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    }
    #expect(try Data(contentsOf: fixture.destination) == existing)
    try FileManager.default.removeItem(at: fixture.destination)
    let missing = fixture.directory.appendingPathComponent("missing-target")
    try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: missing)
    #expect(throws: ScanVideoExportError.destinationExists) {
        try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    }
    #expect(try fixture.destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    let alias = fixture.directory.appendingPathComponent("source-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
    for output in [fixture.source.appendingPathComponent("scan.tar"), alias.appendingPathComponent("scan.tar")] {
        #expect(throws: ScanVideoExportError.invalidDestination) {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: output)
        }
    }
    #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
}

@Test func scanVideoExportStreamsWholeLocalCaptureAboveUploadBodyLimit() throws {
    let fixture = try videoExportFixture(segmentCount: 5, videoBytes: 54 * 1024 * 1024)
    defer { fixture.remove() }
    try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
    let entries = try videoTarEntries(fixture.destination)
    let videoEntries = fixture.manifest.segments.compactMap { entries[fixture.manifest.captureID + "/" + $0.videoAsset] }
    #expect(videoEntries.count == 5)
    #expect(videoEntries.reduce(UInt64(0)) { $0 + $1.bytes } > 256 * 1024 * 1024)
    #expect(videoEntries.allSatisfy { $0.bytes == 54 * 1024 * 1024 })
    #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
}

@Test func scanVideoExportHonorsCancellationAndRemovesPartialOutput() async throws {
    let fixture = try videoExportFixture(segmentCount: 5, videoBytes: 54 * 1024 * 1024)
    defer { fixture.remove() }
    let initial = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination)
            return false
        } catch is CancellationError { return true }
    }
    #expect(try await initial.value)
    #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    let task = Task.detached { try ScanVideoExport.write(captureDirectory: fixture.source, to: fixture.destination) }
    var observedPartial = false
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if !(try videoExportTemporaryFiles(fixture.directory)).isEmpty {
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
    #expect(try videoExportTemporaryFiles(fixture.directory).isEmpty)
}
