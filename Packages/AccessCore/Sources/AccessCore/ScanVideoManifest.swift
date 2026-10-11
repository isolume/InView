import Foundation

/// Local video evidence shares the scan's original ARKit coordinates and monotonic clock.
/// Each completed segment contains video, available byte-exact depth/confidence, and a frame index.
public struct ScanVideoManifest: Codable, Equatable, Sendable {
    public static let maximumFramesPerSegment = 100
    public static let maximumAssetBytes = 64 * 1024 * 1024
    public static let maximumSegments = 10_000

    public var schemaVersion = 2
    public var captureID: String
    public var mapID: String
    public var floorID: String
    public var coordinateFrame = "shared_arkit_session"
    public var coordinates: CaptureCoordinates = .metersYUpRightHanded
    public var clock = "arkit_uptime_seconds"
    public var unixOffsetSeconds: Double
    public var targetFrameRate = 10.0
    /// `recording`, `complete`, or `partial`; only finalized assets belong in `segments`.
    public var status: String
    public var stopReason: String?
    public var skippedSamples: Int
    public var segments: [ScanVideoSegment]

    public init(captureID: String, mapID: String, floorID: String, unixOffsetSeconds: Double,
                status: String = "recording", stopReason: String? = nil,
                skippedSamples: Int = 0, segments: [ScanVideoSegment] = []) {
        self.captureID = captureID; self.mapID = mapID; self.floorID = floorID
        self.unixOffsetSeconds = unixOffsetSeconds; self.status = status; self.stopReason = stopReason
        self.skippedSamples = skippedSamples; self.segments = segments
    }

    public func validate() throws {
        try videoRequire([1, 2].contains(schemaVersion) && coordinateFrame == "shared_arkit_session"
                         && coordinates == .metersYUpRightHanded && clock == "arkit_uptime_seconds",
                         "This scan video format is not supported.")
        try StreamManifest(id: captureID, mapID: mapID, floorID: floorID, coordinates: coordinates).validate()
        try videoRequire(unixOffsetSeconds.isFinite && unixOffsetSeconds > 0
                         && targetFrameRate == 10 && skippedSamples >= 0
                         && ["recording", "complete", "partial"].contains(status)
                         && (status != "complete" || !segments.isEmpty)
                         && (status != "partial" || stopReason != nil)
                         && (status != "recording" || stopReason == nil)
                         && stopReason.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             && $0.utf8.count <= 256 }) != false,
                         "The scan video has invalid recording information.")
        try videoRequire(segments.count <= Self.maximumSegments, "The scan video has too many segments.")
        var end: Double?
        for (index, segment) in segments.enumerated() {
            try segment.validate()
            try videoRequire(schemaVersion != 1 || segment.depthBytes > 0,
                             "A legacy scan video segment requires recorded depth.")
            try videoRequire(segment.id == ScanVideoSegment.identifier(index: index)
                             && end.map({ segment.startTimestampSeconds > $0 }) != false,
                             "The scan video segments are out of order.")
            end = segment.endTimestampSeconds
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", captureID = "capture_id", mapID = "map_id", floorID = "floor_id"
        case coordinateFrame = "coordinate_frame", coordinates, clock, unixOffsetSeconds = "unix_offset_seconds"
        case targetFrameRate = "target_frame_rate", status, stopReason = "stop_reason"
        case skippedSamples = "skipped_samples", segments
    }
}

public struct ScanVideoSegment: Codable, Equatable, Sendable {
    public var id: String
    public var videoAsset: String
    public var depthAsset: String
    public var framesAsset: String
    public var videoBytes: Int
    public var depthBytes: Int
    public var framesBytes: Int
    public var frameCount: Int
    public var startTimestampSeconds: Double
    public var endTimestampSeconds: Double

    public init(id: String, videoAsset: String, depthAsset: String, framesAsset: String,
                videoBytes: Int, depthBytes: Int, framesBytes: Int, frameCount: Int,
                startTimestampSeconds: Double, endTimestampSeconds: Double) {
        self.id = id; self.videoAsset = videoAsset; self.depthAsset = depthAsset; self.framesAsset = framesAsset
        self.videoBytes = videoBytes; self.depthBytes = depthBytes; self.framesBytes = framesBytes
        self.frameCount = frameCount; self.startTimestampSeconds = startTimestampSeconds
        self.endTimestampSeconds = endTimestampSeconds
    }

    public static func identifier(index: Int) -> String {
        let digits = String(index)
        return "video-" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    public func validate() throws {
        try videoRequire(videoSegmentID(id) && videoAsset == id + ".mp4"
                         && depthAsset == id + ".depth.bin" && framesAsset == id + ".frames.json"
                         && [videoBytes, framesBytes].allSatisfy {
                             (1...ScanVideoManifest.maximumAssetBytes).contains($0)
                         } && (0...ScanVideoManifest.maximumAssetBytes).contains(depthBytes)
                         && (1...ScanVideoManifest.maximumFramesPerSegment).contains(frameCount)
                         && videoTime(startTimestampSeconds) && videoTime(endTimestampSeconds)
                         && endTimestampSeconds >= startTimestampSeconds,
                         "The scan video segment is incomplete or invalid.")
    }

    enum CodingKeys: String, CodingKey {
        case id, videoAsset = "video_asset", depthAsset = "depth_asset", framesAsset = "frames_asset"
        case videoBytes = "video_bytes", depthBytes = "depth_bytes", framesBytes = "frames_bytes"
        case frameCount = "frame_count", startTimestampSeconds = "start_timestamp_seconds"
        case endTimestampSeconds = "end_timestamp_seconds"
    }
}

/// Intrinsics describe sensor-native encoded pixels; the MP4 track rotates their display 90° clockwise.
public struct ScanVideoFrameDocument: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var segmentID: String
    public var videoAsset: String
    public var depthAsset: String
    public var videoWidth: Int
    public var videoHeight: Int
    public var pixelOrientation = "sensor_native_with_90_cw_display_transform"
    public var frames: [ScanVideoFrame]

    public init(segmentID: String, videoAsset: String, depthAsset: String, videoWidth: Int,
                videoHeight: Int, frames: [ScanVideoFrame]) {
        self.segmentID = segmentID; self.videoAsset = videoAsset; self.depthAsset = depthAsset
        self.videoWidth = videoWidth; self.videoHeight = videoHeight; self.frames = frames
    }

    /// Validates every byte range and requires the depth sidecar to contain exactly the indexed bytes.
    public func validate(depthBytes: Int) throws {
        try videoRequire([1, 2].contains(schemaVersion) && videoSegmentID(segmentID)
                         && videoAsset == segmentID + ".mp4" && depthAsset == segmentID + ".depth.bin"
                         && pixelOrientation == "sensor_native_with_90_cw_display_transform"
                         && (1...1280).contains(videoWidth) && (1...1280).contains(videoHeight)
                         && videoWidth >= videoHeight
                         && (1...ScanVideoManifest.maximumFramesPerSegment).contains(frames.count)
                         && (0...ScanVideoManifest.maximumAssetBytes).contains(depthBytes)
                         && (schemaVersion != 1 || depthBytes > 0),
                         "The scan video frame index is invalid.")
        var offset = 0
        var previous: Double?
        let first = frames[0].timestampSeconds
        for (index, frame) in frames.enumerated() {
            try frame.validate()
            try videoRequire(frame.index == index && frame.videoCamera.imageWidth == videoWidth
                             && frame.videoCamera.imageHeight == videoHeight
                             && previous.map({ frame.timestampSeconds > $0 }) != false
                             && abs(frame.presentationTimeSeconds - (frame.timestampSeconds - first)) <= 0.000001,
                             "The scan video frame timing or calibration is inconsistent.")
            if let depth = frame.rawDepth {
                offset = try depth.validate(expectedOffset: offset, maximumBytes: depthBytes)
            } else {
                try videoRequire(schemaVersion != 1, "A legacy scan video frame requires recorded depth.")
            }
            previous = frame.timestampSeconds
        }
        try videoRequire(offset == depthBytes, "The scan video depth sidecar has unindexed bytes.")
    }

    public func validate(segment: ScanVideoSegment) throws {
        try segment.validate()
        try validate(depthBytes: segment.depthBytes)
        try videoRequire(segment.id == segmentID && segment.videoAsset == videoAsset
                         && segment.depthAsset == depthAsset && segment.frameCount == frames.count
                         && segment.startTimestampSeconds == frames.first?.timestampSeconds
                         && segment.endTimestampSeconds == frames.last?.timestampSeconds,
                         "The scan video frame index does not match its segment.")
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", segmentID = "segment_id", videoAsset = "video_asset"
        case depthAsset = "depth_asset", videoWidth = "video_width", videoHeight = "video_height"
        case pixelOrientation = "pixel_orientation", frames
    }
}

/// One successfully encoded RGB image, pose, and any depth available on that exact ARFrame.
public struct ScanVideoFrame: Codable, Equatable, Sendable {
    public var index: Int
    public var timestampSeconds: Double
    public var presentationTimeSeconds: Double
    public var mapFromCamera: [Float]
    public var sensorCamera: CaptureCameraCalibration
    public var videoCamera: CaptureCameraCalibration
    public var tracking: String
    public var mapping: String
    /// Absent when the ARFrame provided no measured depth; pose and calibration remain valid.
    public var rawDepth: ScanVideoDepth?

    public init(index: Int, timestampSeconds: Double, presentationTimeSeconds: Double,
                mapFromCamera: [Float], sensorCamera: CaptureCameraCalibration,
                videoCamera: CaptureCameraCalibration, tracking: String, mapping: String,
                rawDepth: ScanVideoDepth? = nil) {
        self.index = index; self.timestampSeconds = timestampSeconds
        self.presentationTimeSeconds = presentationTimeSeconds; self.mapFromCamera = mapFromCamera
        self.sensorCamera = sensorCamera; self.videoCamera = videoCamera
        self.tracking = tracking; self.mapping = mapping; self.rawDepth = rawDepth
    }

    public func validate() throws {
        try videoRequire((0..<ScanVideoManifest.maximumFramesPerSegment).contains(index)
                         && videoTime(timestampSeconds) && videoTime(presentationTimeSeconds)
                         && validRigidTransform(mapFromCamera) && tracking == "normal"
                         && ["not_available", "limited", "extending", "mapped"].contains(mapping)
                         && videoCalibration(sensorCamera) && videoCalibration(videoCamera)
                         && sensorCamera.imageWidth >= sensorCamera.imageHeight
                         && videoCamera.imageWidth <= sensorCamera.imageWidth
                         && videoCamera.imageHeight <= sensorCamera.imageHeight
                         && max(videoCamera.imageWidth, videoCamera.imageHeight) <= 1280,
                         "A scan video frame has invalid measurements or tracking.")
        let sx = Float(videoCamera.imageWidth) / Float(sensorCamera.imageWidth)
        let sy = Float(videoCamera.imageHeight) / Float(sensorCamera.imageHeight)
        try videoRequire(abs(sx - sy) <= 0.000001
                         && videoNear(videoCamera.fx, sensorCamera.fx * sx)
                         && videoNear(videoCamera.fy, sensorCamera.fy * sy)
                         && videoNear(videoCamera.cx, sensorCamera.cx * sx)
                         && videoNear(videoCamera.cy, sensorCamera.cy * sy),
                         "A scan video frame does not align its camera calibration.")
        if let rawDepth {
            try videoRequire((1...1024).contains(rawDepth.width) && (1...1024).contains(rawDepth.height)
                             && sensorCamera.imageWidth * rawDepth.height == sensorCamera.imageHeight * rawDepth.width,
                             "A scan video frame does not align its camera and depth.")
            _ = try rawDepth.validate(expectedOffset: rawDepth.offset, maximumBytes: Int.max)
        }
    }

    enum CodingKeys: String, CodingKey {
        case index, timestampSeconds = "timestamp_seconds", presentationTimeSeconds = "presentation_time_seconds"
        case mapFromCamera = "map_from_camera", sensorCamera = "sensor_camera", videoCamera = "video_camera"
        case tracking, mapping, rawDepth = "raw_depth"
    }
}

/// Native row strides and raw float bits survive without JSON/base64 or depth resampling.
public struct ScanVideoDepth: Codable, Equatable, Sendable {
    public static let float32PixelFormat: UInt32 = 1_717_855_600
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var pixelFormat: UInt32
    public var offset: Int
    public var length: Int
    public var confidenceOffset: Int?
    public var confidenceLength: Int?
    public var confidenceBytesPerRow: Int?

    public init(width: Int, height: Int, bytesPerRow: Int,
                pixelFormat: UInt32 = ScanVideoDepth.float32PixelFormat, offset: Int, length: Int,
                confidenceOffset: Int? = nil, confidenceLength: Int? = nil, confidenceBytesPerRow: Int? = nil) {
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow; self.pixelFormat = pixelFormat
        self.offset = offset; self.length = length; self.confidenceOffset = confidenceOffset
        self.confidenceLength = confidenceLength; self.confidenceBytesPerRow = confidenceBytesPerRow
    }

    /// Returns the next free byte, rejecting gaps, overlaps, overflow, and out-of-bounds rows.
    public func validate(expectedOffset: Int, maximumBytes: Int) throws -> Int {
        try videoRequire((1...1024).contains(width) && (1...1024).contains(height)
                         && (width * 4...8192).contains(bytesPerRow) && bytesPerRow.isMultiple(of: 4)
                         && pixelFormat == Self.float32PixelFormat && expectedOffset >= 0
                         && maximumBytes >= 0 && offset == expectedOffset
                         && length == bytesPerRow * height,
                         "A scan video depth range is invalid.")
        let depthEnd = offset.addingReportingOverflow(length)
        try videoRequire(!depthEnd.overflow && depthEnd.partialValue <= maximumBytes,
                         "A scan video depth range exceeds its sidecar.")
        let fields = [confidenceOffset, confidenceLength, confidenceBytesPerRow]
        guard fields.contains(where: { $0 != nil }) else { return depthEnd.partialValue }
        guard let confidenceOffset, let confidenceLength, let stride = confidenceBytesPerRow else {
            throw CaptureValidationError.invalid("The scan video confidence range is incomplete.")
        }
        try videoRequire((width...8192).contains(stride) && confidenceOffset == depthEnd.partialValue
                         && confidenceLength == stride * height,
                         "The scan video confidence range is invalid.")
        let end = confidenceOffset.addingReportingOverflow(confidenceLength)
        try videoRequire(!end.overflow && end.partialValue <= maximumBytes,
                         "The scan video confidence range exceeds its sidecar.")
        return end.partialValue
    }

    enum CodingKeys: String, CodingKey {
        case width, height, bytesPerRow = "bytes_per_row", pixelFormat = "pixel_format", offset, length
        case confidenceOffset = "confidence_offset", confidenceLength = "confidence_length"
        case confidenceBytesPerRow = "confidence_bytes_per_row"
    }
}

private func videoRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw CaptureValidationError.invalid(message) }
}

private func videoSegmentID(_ value: String) -> Bool {
    value.utf8.count == 10 && value.hasPrefix("video-")
        && value.dropFirst(6).allSatisfy { $0.isASCII && $0.isNumber }
}

private func videoTime(_ value: Double) -> Bool { value.isFinite && value >= 0 }

private func videoCalibration(_ camera: CaptureCameraCalibration) -> Bool {
    (1...16_384).contains(camera.imageWidth) && (1...16_384).contains(camera.imageHeight)
        && [camera.fx, camera.fy, camera.cx, camera.cy].allSatisfy(\.isFinite)
        && camera.fx > 0 && camera.fy > 0 && camera.cx >= 0 && camera.cy >= 0
        && camera.cx <= Float(camera.imageWidth) && camera.cy <= Float(camera.imageHeight)
}

private func videoNear(_ value: Float, _ expected: Float) -> Bool {
    abs(value - expected) <= max(0.0001, abs(expected) * 0.00001)
}
