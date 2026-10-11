import Foundation
import Testing
@testable import AccessCore

private let videoTestIdentity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func videoTestDocument() -> ScanVideoFrameDocument {
    let sensor = CaptureCameraCalibration(imageWidth: 1920, imageHeight: 1440,
                                          fx: 1000, fy: 1002, cx: 959.5, cy: 719.5)
    let scale: Float = 2 / 3
    let video = CaptureCameraCalibration(imageWidth: 1280, imageHeight: 960,
                                         fx: sensor.fx * scale, fy: sensor.fy * scale,
                                         cx: sensor.cx * scale, cy: sensor.cy * scale)
    let timestamps = [125.4, 125.625]
    let frames = timestamps.enumerated().map { index, timestamp in
        var pose = videoTestIdentity
        pose[12] = Float(index) * 0.25
        return ScanVideoFrame(index: index, timestampSeconds: timestamp,
                              presentationTimeSeconds: timestamp - timestamps[0], mapFromCamera: pose,
                              sensorCamera: sensor, videoCamera: video, tracking: "normal", mapping: "mapped",
                              rawDepth: ScanVideoDepth(width: 4, height: 3, bytesPerRow: 20,
                                                       offset: index * 84, length: 60,
                                                       confidenceOffset: index * 84 + 60,
                                                       confidenceLength: 24, confidenceBytesPerRow: 8))
    }
    return ScanVideoFrameDocument(segmentID: "video-0000", videoAsset: "video-0000.mp4",
                                  depthAsset: "video-0000.depth.bin", videoWidth: 1280,
                                  videoHeight: 960, frames: frames)
}

private func videoTestSegment(_ document: ScanVideoFrameDocument = videoTestDocument()) throws -> ScanVideoSegment {
    ScanVideoSegment(id: document.segmentID, videoAsset: document.videoAsset, depthAsset: document.depthAsset,
                     framesAsset: document.segmentID + ".frames.json", videoBytes: 400, depthBytes: 168,
                     framesBytes: try JSONEncoder().encode(document).count, frameCount: document.frames.count,
                     startTimestampSeconds: document.frames[0].timestampSeconds,
                     endTimestampSeconds: document.frames[document.frames.count - 1].timestampSeconds)
}

private func videoTestManifest() throws -> ScanVideoManifest {
    ScanVideoManifest(captureID: "8255C453-666B-441C-86ED-0D3B4092018F", mapID: "building",
                      floorID: "second", unixOffsetSeconds: 1_800_000_000, status: "complete",
                      skippedSamples: 3, segments: [try videoTestSegment()])
}

struct ScanVideoManifestTests {
    @Test func videoEvidenceRoundTripsExactTimestampsCalibrationAndNativeRowPadding() throws {
        let document = videoTestDocument()
        let segment = try videoTestSegment(document)
        let manifest = try videoTestManifest()
        try document.validate(segment: segment)
        try manifest.validate()
        let documentData = try JSONEncoder().encode(document)
        let savedDocument = try JSONDecoder().decode(ScanVideoFrameDocument.self, from: documentData)
        let manifestData = try JSONEncoder().encode(manifest)
        let savedManifest = try JSONDecoder().decode(ScanVideoManifest.self, from: manifestData)
        #expect(savedDocument == document)
        #expect(savedManifest == manifest)
        #expect(savedDocument.schemaVersion == 2 && savedManifest.schemaVersion == 2)
        #expect(savedDocument.frames[1].timestampSeconds == 125.625)
        #expect(savedDocument.frames[1].presentationTimeSeconds == 125.625 - 125.4)
        #expect(savedDocument.frames[0].rawDepth?.bytesPerRow == 20)
        #expect(savedDocument.frames[0].rawDepth?.confidenceBytesPerRow == 8)
        #expect(savedDocument.frames[0].sensorCamera.imageWidth == 1920)
        #expect(savedDocument.frames[0].videoCamera.imageWidth == 1280)
        let object = try #require(JSONSerialization.jsonObject(with: documentData) as? [String: Any])
        #expect(object["pixel_orientation"] as? String == "sensor_native_with_90_cw_display_transform")
        let records = try #require(object["frames"] as? [[String: Any]])
        #expect(records[0]["sensor_camera"] != nil)
        #expect(records[0]["video_camera"] != nil)
        #expect(records[0]["map_from_camera"] != nil)
        #expect(records[0]["timestamp_seconds"] != nil)
    }

    @Test func videoManifestStatesRetainPartialEvidenceAndDoNotClaimAnEmptyCompleteRecording() throws {
        var manifest = try videoTestManifest()
        manifest.status = "partial"
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
        manifest.stopReason = "storage_limit"
        try manifest.validate()
        manifest.segments = []
        try manifest.validate()
        manifest.status = "complete"
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
        manifest.status = "recording"
        manifest.stopReason = nil
        try manifest.validate()
        manifest.stopReason = "storage_limit"
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
    }

    @Test func videoManifestRejectsUnknownVersionCoordinatesClocksAndRecordingMetadata() throws {
        let changes: [(inout ScanVideoManifest) -> Void] = [
            { $0.schemaVersion = 3 }, { $0.coordinateFrame = "optimized" }, { $0.coordinates.units = "feet" },
            { $0.clock = "unix_seconds" }, { $0.unixOffsetSeconds = .infinity }, { $0.targetFrameRate = 30 },
            { $0.status = "done" }, { $0.skippedSamples = -1 }, { $0.stopReason = "   " },
        ]
        for change in changes {
            var manifest = try videoTestManifest()
            change(&manifest)
            #expect(throws: CaptureValidationError.self) { try manifest.validate() }
        }
        var manifest = try videoTestManifest()
        manifest.captureID = "../capture"
        #expect(throws: StreamingCaptureError.invalidManifest) { try manifest.validate() }
    }

    @Test func videoSegmentPathsMustBeCanonicalAndSafe() throws {
        let changes: [(inout ScanVideoSegment) -> Void] = [
            { $0.id = "video-000x" }, { $0.id = "../video-0" },
            { $0.videoAsset = "../video-0000.mp4" }, { $0.depthAsset = "/video-0000.depth.bin" },
            { $0.framesAsset = "video-0000/frames.json" }, { $0.framesAsset = "video-0001.frames.json" },
            { $0.videoBytes = 0 }, { $0.depthBytes = ScanVideoManifest.maximumAssetBytes + 1 },
            { $0.depthBytes = -1 }, { $0.framesBytes = 0 },
            { $0.frameCount = 101 }, { $0.endTimestampSeconds = 1 },
        ]
        for change in changes {
            var segment = try videoTestSegment()
            change(&segment)
            #expect(throws: CaptureValidationError.self) { try segment.validate() }
        }
    }

    @Test func videoManifestSegmentsCannotRepeatOverlapOrSkipTheirSequence() throws {
        var manifest = try videoTestManifest()
        var next = manifest.segments[0]
        next.id = "video-0001"; next.videoAsset = "video-0001.mp4"
        next.depthAsset = "video-0001.depth.bin"; next.framesAsset = "video-0001.frames.json"
        next.startTimestampSeconds = 130; next.endTimestampSeconds = 131
        manifest.segments.append(next)
        try manifest.validate()
        manifest.segments[1].startTimestampSeconds = manifest.segments[0].endTimestampSeconds
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
        manifest.segments[1] = manifest.segments[0]
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
        manifest.segments = [next]
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
    }

    @Test func videoFrameTimingMustMatchExactARFrameAndEncodedPresentationOrder() throws {
        let changes: [(inout ScanVideoFrameDocument) -> Void] = [
            { $0.frames[0].presentationTimeSeconds = 0.1 }, { $0.frames[1].presentationTimeSeconds += 0.01 },
            { $0.frames[1].timestampSeconds = $0.frames[0].timestampSeconds }, { $0.frames[1].index = 0 },
            { $0.frames[1].timestampSeconds = .nan }, { $0.frames[1].presentationTimeSeconds = -.infinity },
        ]
        for change in changes {
            var document = videoTestDocument()
            change(&document)
            #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 168) }
        }
    }

    @Test func videoFrameRejectsBadPoseTrackingAndMisalignedCalibration() throws {
        let changes: [(inout ScanVideoFrame) -> Void] = [
            { $0.mapFromCamera[0] = 2 }, { $0.mapFromCamera[12] = .nan }, { $0.mapFromCamera.removeLast() },
            { $0.tracking = "limited:relocalizing" }, { $0.tracking = "not_available" }, { $0.mapping = "ready" },
            { $0.sensorCamera.fx = 0 }, { $0.videoCamera.cy = .infinity }, { $0.sensorCamera.cx = -1 },
            { $0.videoCamera.imageHeight = 950 }, { $0.videoCamera.fx += 1 }, { $0.rawDepth?.height = 4 },
        ]
        for change in changes {
            var frame = videoTestDocument().frames[0]
            change(&frame)
            #expect(throws: CaptureValidationError.self) { try frame.validate() }
        }
    }

    @Test func videoDepthRejectsGapsOverlapsIncompleteConfidenceAndWrongNativeLayout() throws {
        let changes: [(inout ScanVideoFrameDocument) -> Void] = [
            { $0.frames[0].rawDepth?.offset = 1 }, { $0.frames[1].rawDepth?.offset = 83 },
            { $0.frames[1].rawDepth?.offset = 85 }, { $0.frames[0].rawDepth?.confidenceOffset = 59 },
            { $0.frames[0].rawDepth?.confidenceOffset = 61 }, { $0.frames[0].rawDepth?.length = 48 },
            { $0.frames[0].rawDepth?.bytesPerRow = 16 }, { $0.frames[0].rawDepth?.pixelFormat = 0 },
            { $0.frames[0].rawDepth?.confidenceBytesPerRow = nil }, { $0.frames[0].rawDepth?.confidenceLength = 12 },
        ]
        for change in changes {
            var document = videoTestDocument()
            change(&document)
            #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 168) }
        }
        let document = videoTestDocument()
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 167) }
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 169) }
    }

    @Test func videoDepthChecksOverflowBeforeUsingSidecarOffsets() throws {
        var depth = try #require(videoTestDocument().frames[0].rawDepth)
        depth.offset = Int.max - 1
        #expect(throws: CaptureValidationError.self) {
            try depth.validate(expectedOffset: Int.max - 1, maximumBytes: Int.max)
        }
        depth = try #require(videoTestDocument().frames[0].rawDepth)
        depth.bytesPerRow = Int.max
        #expect(throws: CaptureValidationError.self) { try depth.validate(expectedOffset: 0, maximumBytes: Int.max) }
        depth = try #require(videoTestDocument().frames[0].rawDepth)
        depth.confidenceBytesPerRow = Int.max
        #expect(throws: CaptureValidationError.self) { try depth.validate(expectedOffset: 0, maximumBytes: Int.max) }
    }

    @Test func videoDepthCanExplicitlyRepresentUnavailableConfidenceWithoutInventingIt() throws {
        var document = videoTestDocument()
        for index in document.frames.indices {
            document.frames[index].rawDepth?.offset = index * 60
            document.frames[index].rawDepth?.confidenceOffset = nil
            document.frames[index].rawDepth?.confidenceLength = nil
            document.frames[index].rawDepth?.confidenceBytesPerRow = nil
        }
        try document.validate(depthBytes: 120)
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(ScanVideoFrameDocument.self, from: data) == document)
        #expect(!String(decoding: data, as: UTF8.self).contains("confidence_offset"))
    }

    @Test func videoFramesWithoutMeasuredDepthRetainExactPoseCalibrationAndTiming() throws {
        var document = videoTestDocument()
        for index in document.frames.indices { document.frames[index].rawDepth = nil }
        try document.validate(depthBytes: 0)
        var segment = try videoTestSegment(document)
        segment.depthBytes = 0
        try document.validate(segment: segment)
        var manifest = try videoTestManifest()
        manifest.segments = [segment]
        try manifest.validate()
        let data = try JSONEncoder().encode(document)
        let saved = try JSONDecoder().decode(ScanVideoFrameDocument.self, from: data)
        #expect(saved == document)
        #expect(saved.frames[1].mapFromCamera[12] == 0.25)
        #expect(saved.frames[1].timestampSeconds == 125.625)
        #expect(saved.frames[1].videoCamera == videoTestDocument().frames[1].videoCamera)
        #expect(!String(decoding: data, as: UTF8.self).contains("raw_depth"))
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 1) }
        document.frames[0].mapFromCamera[0] = 2
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 0) }
        document = saved
        document.frames[0].videoCamera.fx += 1
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 0) }
    }

    @Test func mixedVideoFramesIndexOnlyMeasuredDepthWithoutReservingBytesForAbsentDepth() throws {
        let original = videoTestDocument()
        var document = original
        let timestamps = [125.3, 125.4, 125.5, 125.625, 125.8]
        document.frames = timestamps.enumerated().map { index, timestamp in
            var frame = original.frames[index == 3 ? 1 : 0]
            frame.index = index
            frame.timestampSeconds = timestamp
            frame.presentationTimeSeconds = timestamp - timestamps[0]
            if index != 1 && index != 3 { frame.rawDepth = nil }
            return frame
        }
        try document.validate(depthBytes: 168)
        #expect(document.frames[1].rawDepth?.offset == 0)
        #expect(document.frames[3].rawDepth?.offset == 84)
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(ScanVideoFrameDocument.self, from: data) == document)
        document.frames[3].rawDepth?.offset = 85
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 169) }
        document.frames[3].rawDepth?.offset = 83
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 168) }
    }

    @Test func legacyVideoDocumentsRequireDepthOnEveryFrameAndNonemptyDepthSegments() throws {
        var document = videoTestDocument()
        document.schemaVersion = 1
        var segment = try videoTestSegment(document)
        var manifest = try videoTestManifest()
        manifest.schemaVersion = 1
        manifest.segments = [segment]
        try document.validate(segment: segment)
        try manifest.validate()
        let data = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(ScanVideoFrameDocument.self, from: data) == document)
        document.frames[0].rawDepth = nil
        document.frames[1].rawDepth?.offset = 0
        document.frames[1].rawDepth?.confidenceOffset = 60
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 84) }
        document.schemaVersion = 2
        try document.validate(depthBytes: 84)
        document.schemaVersion = 1
        for index in document.frames.indices { document.frames[index].rawDepth = nil }
        #expect(throws: CaptureValidationError.self) { try document.validate(depthBytes: 0) }
        segment.depthBytes = 0
        manifest.segments = [segment]
        #expect(throws: CaptureValidationError.self) { try manifest.validate() }
    }

    @Test func videoFrameIndexCrossChecksSegmentIdentityCountAndTimeline() throws {
        let document = videoTestDocument()
        let changes: [(inout ScanVideoSegment) -> Void] = [
            { $0.frameCount = 1 }, { $0.startTimestampSeconds -= 1 }, { $0.endTimestampSeconds += 1 },
            { $0.depthBytes += 1 },
            { $0.id = "video-0001"; $0.videoAsset = "video-0001.mp4"
                $0.depthAsset = "video-0001.depth.bin"; $0.framesAsset = "video-0001.frames.json" },
        ]
        for change in changes {
            var segment = try videoTestSegment()
            change(&segment)
            #expect(throws: CaptureValidationError.self) { try document.validate(segment: segment) }
        }
        var invalid = document
        invalid.schemaVersion = 3
        #expect(throws: CaptureValidationError.self) { try invalid.validate(depthBytes: 168) }
        invalid = document
        invalid.pixelOrientation = "portrait"
        #expect(throws: CaptureValidationError.self) { try invalid.validate(depthBytes: 168) }
    }
}
