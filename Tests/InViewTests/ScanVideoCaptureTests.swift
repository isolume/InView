import AccessCore
import AVFoundation
import CoreVideo
import XCTest
@testable import InView

final class ScanVideoCaptureTests: XCTestCase {
    private let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    func testVideoDimensionsPreserveCalibrationForAnUncommonAspectRatio() throws {
        let dimensions = try XCTUnwrap(ScanVideoWriter.videoDimensions(width: 1920, height: 1088))
        XCTAssertEqual(dimensions.0, 1260)
        XCTAssertEqual(dimensions.1, 714)
        XCTAssertEqual(Double(dimensions.0) / 1920, Double(dimensions.1) / 1088, accuracy: 0.000001)
    }

    private func sample(at timestamp: Double) throws -> ScanVideoSample {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var depth = Data()
        // Preserve native row padding and a real IEEE754 NaN instead of fabricating a surface.
        for bits in [UInt32(0x3f800000), 0x40000000, 0x7fc00000, 0x40800000,
                     0x3f800000, 0x40000000, 0x40400000, 0x40800000,
                     0x3f800000, 0x40000000, 0x40400000, 0x40800000] {
            var value = bits.littleEndian
            withUnsafeBytes(of: &value) { depth.append(contentsOf: $0) }
        }
        return ScanVideoSample(pixels: try XCTUnwrap(FrameEncoder.snapshot(pixels)), timestamp: timestamp,
            mapFromCamera: identity, camera: .init(imageWidth: 64, imageHeight: 48, fx: 50, fy: 50, cx: 32, cy: 24),
            mapping: "mapped", depth: depth, depthWidth: 4, depthHeight: 3, depthBytesPerRow: 16,
            confidence: Data(repeating: 2, count: 12), confidenceBytesPerRow: 4)
    }

    func testEncodedSamplesHaveMatchingTimestampsDepthAndPlaybackRotationAcrossSegments() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "video-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID().uuidString
        let writer = ScanVideoWriter(folder: folder, captureID: id, mapID: id, floorID: "ground",
            policy: .init(framesPerSegment: 2, minimumFreeBytes: 0))
        var count = 0
        var timestamp = 100.0
        // Readiness may drop real-time input while the hardware encoder initializes.
        for _ in 0..<30 {
            count = try await writer.append(sample(at: timestamp))
            timestamp += 0.103827
            if count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(count, 3)
        let saved = try await writer.finish(reason: nil, skippedSamples: 0)
        XCTAssertEqual(saved, 3)
        let manifest = try JSONDecoder().decode(ScanVideoManifest.self,
            from: Data(contentsOf: folder.appending(path: "video-manifest.json")))
        try manifest.validate()
        XCTAssertEqual(manifest.status, "complete")
        XCTAssertEqual(manifest.segments.map(\.frameCount), [2, 1])
        for segment in manifest.segments {
            let document = try JSONDecoder().decode(ScanVideoFrameDocument.self,
                from: Data(contentsOf: folder.appending(path: segment.framesAsset)))
            try document.validate(segment: segment)
            let depth = try Data(contentsOf: folder.appending(path: segment.depthAsset))
            for frame in document.frames {
                XCTAssertEqual(frame.mapFromCamera, identity)
                XCTAssertEqual(depth.subdata(in: frame.rawDepth.offset..<(frame.rawDepth.offset + frame.rawDepth.length)),
                               try sample(at: frame.timestampSeconds).depth)
                XCTAssertEqual(frame.presentationTimeSeconds, frame.timestampSeconds - document.frames[0].timestampSeconds,
                               accuracy: 0.000001)
            }
            let asset = AVURLAsset(url: folder.appending(path: segment.videoAsset))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let transform = try await track.load(.preferredTransform)
            XCTAssertEqual(transform.b, 1, accuracy: 0.001)
            XCTAssertEqual(transform.c, -1, accuracy: 0.001)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            print("VIDEO_TIMES actual=\(times) indexed=\(document.frames.map(\.presentationTimeSeconds))")
            XCTAssertEqual(times.count, document.frames.count)
            for (actual, frame) in zip(times, document.frames) {
                XCTAssertEqual(actual, frame.presentationTimeSeconds, accuracy: 0.000001)
            }
        }
    }

    func testStorageLimitBeforeTheFirstFrameRecordsAnExplicitReason() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "video-limit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID().uuidString
        let writer = ScanVideoWriter(folder: folder, captureID: id, mapID: id, floorID: "ground",
            policy: .init(maximumRecordedBytes: 1, minimumFreeBytes: 0))
        do {
            _ = try await writer.append(sample(at: 100))
            XCTFail("The storage limit should stop video before encoding.")
        } catch ScanVideoRecordingError.storageLimit {}
        let saved = try await writer.finish(reason: "storage_limit", skippedSamples: 2)
        XCTAssertEqual(saved, 0)
        let manifest = try JSONDecoder().decode(ScanVideoManifest.self,
            from: Data(contentsOf: folder.appending(path: "video-manifest.json")))
        try manifest.validate()
        XCTAssertEqual(manifest.status, "partial")
        XCTAssertEqual(manifest.stopReason, "storage_limit")
        XCTAssertEqual(manifest.skippedSamples, 2)
    }

    func testStorageExhaustionPreservesFinalizedSegmentsAndFinishStopsFurtherWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "video-partial-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID().uuidString
        let writer = ScanVideoWriter(folder: folder, captureID: id, mapID: id, floorID: "ground",
            policy: .init(framesPerSegment: 1, maximumRecordedBytes: 1024 * 1024 + 8192, minimumFreeBytes: 0))
        var exhausted = false
        for index in 0..<50 {
            do { _ = try await writer.append(sample(at: 100 + Double(index) * 0.103827)) }
            catch ScanVideoRecordingError.storageLimit { exhausted = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(exhausted)
        let count = try await writer.finish(reason: "storage_limit", skippedSamples: 0)
        XCTAssertGreaterThan(count, 0)
        let manifestURL = folder.appending(path: "video-manifest.json")
        let before = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ScanVideoManifest.self, from: before)
        try manifest.validate()
        XCTAssertEqual(manifest.status, "partial")
        XCTAssertEqual(manifest.stopReason, "storage_limit")
        for segment in manifest.segments {
            let document = try JSONDecoder().decode(ScanVideoFrameDocument.self,
                from: Data(contentsOf: folder.appending(path: segment.framesAsset)))
            try document.validate(segment: segment)
            let depth = try Data(contentsOf: folder.appending(path: segment.depthAsset))
            XCTAssertEqual(depth.count, segment.depthBytes)
            XCTAssertEqual(depth.prefix(48), try sample(at: document.frames[0].timestampSeconds).depth)
        }
        let after = try await writer.append(sample(at: 200))
        XCTAssertEqual(after, count)
        XCTAssertEqual(try Data(contentsOf: manifestURL), before)
    }
}
