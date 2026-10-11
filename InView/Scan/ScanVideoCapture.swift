import AccessCore
import ARKit
import AVFoundation
import CoreVideo
import Foundation

/// Copies one synchronized RGB/depth sample at a time without taking RoomPlan's delegate.
@MainActor
final class ScanVideoCapture {
    var onStatus: ((String) -> Void)?
    private weak var session: ARSession?
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var writer: ScanVideoWriter?
    private var lastTimestamp: Double?
    private var skippedSamples = 0
    private var stopped = false
    private var finished = false

    func start(session: ARSession, captureID: UUID, floor: ScanFloorIdentity?) throws {
        let folder = try CaptureStore.captureDirectory(for: captureID.uuidString)
        writer = ScanVideoWriter(folder: folder, captureID: captureID.uuidString,
                                 mapID: captureID.uuidString, floorID: floor?.id.uuidString ?? "ground")
        self.session = session
        resume()
    }

    func resume() {
        guard timer == nil, writer != nil, session != nil, !stopped, !finished else { return }
        onStatus?("Recording video")
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        if writer != nil, !stopped, !finished { onStatus?("Video paused") }
    }

    func finish(reason: String? = nil) async {
        pause()
        finished = true
        session = nil
        if let worker { await worker.value }
        guard let writer else { return }
        do {
            let count = try await writer.finish(reason: reason, skippedSamples: skippedSamples)
            let isPartial = await writer.isPartial
            if !stopped {
                onStatus?(count > 0 ? (isPartial ? "Partial video saved" : "Video saved") : "No video frames saved")
            }
        } catch {
            stopped = true
            onStatus?("Video couldn't be saved. Earlier segments are kept.")
        }
    }

    /// Closing a scan seals accepted evidence; it does not cancel an in-flight sensor copy.
    func stop() {
        pause()
        Task { await finish(reason: "scan_closed") }
    }

    private func sample() {
        guard !stopped, !finished, let writer, let frame = session?.currentFrame,
              lastTimestamp.map({ frame.timestamp - $0 >= 0.075 }) ?? true else { return }
        guard worker == nil else { skippedSamples += 1; return }
        guard case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1,
              let sample = ScanVideoSample.copy(frame) else {
            skippedSamples += 1
            return
        }
        lastTimestamp = frame.timestamp
        worker = Task { [weak self] in
            do {
                let count = try await writer.append(sample)
                guard let self else { return }
                if timer != nil { onStatus?(count > 0 ? "Recording video" : "Waiting for video") }
            } catch {
                guard let self else { return }
                stopped = true
                pause()
                let reason = (error as? ScanVideoRecordingError)?.reason ?? "recording_failed"
                _ = try? await writer.finish(reason: reason, skippedSamples: skippedSamples)
                onStatus?((error as? ScanVideoRecordingError)?.errorDescription
                          ?? "Video stopped. Earlier segments are kept; scanning can continue.")
            }
            self?.worker = nil
        }
    }
}

struct ScanVideoSample: Sendable {
    var pixels: FrameEncoder.Snapshot
    var timestamp: Double
    var mapFromCamera: [Float]
    var camera: CaptureCameraCalibration
    var mapping: String
    var depth: Data
    var depthWidth: Int
    var depthHeight: Int
    var depthBytesPerRow: Int
    var confidence: Data?
    var confidenceBytesPerRow: Int?

    static func copy(_ frame: ARFrame) -> Self? {
        guard let depth = frame.sceneDepth,
              CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32,
              let bytes = copyBytes(depth.depthMap, bytesPerPixel: 4),
              let pixels = FrameEncoder.snapshot(frame.capturedImage) else { return nil }
        let confidence = depth.confidenceMap.flatMap { copyBytes($0, bytesPerPixel: 1) }
        if depth.confidenceMap != nil, confidence == nil { return nil }
        if let buffer = depth.confidenceMap {
            guard CVPixelBufferGetWidth(buffer) == CVPixelBufferGetWidth(depth.depthMap),
                  CVPixelBufferGetHeight(buffer) == CVPixelBufferGetHeight(depth.depthMap),
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        }
        let camera = frame.camera
        guard Int(camera.imageResolution.width) == CVPixelBufferGetWidth(frame.capturedImage),
              Int(camera.imageResolution.height) == CVPixelBufferGetHeight(frame.capturedImage) else { return nil }
        let m = camera.transform
        let k = camera.intrinsics
        return Self(pixels: pixels, timestamp: frame.timestamp,
                    mapFromCamera: (0..<4).flatMap { column in (0..<4).map { m[column][$0] } },
                    camera: .init(imageWidth: Int(camera.imageResolution.width),
                                  imageHeight: Int(camera.imageResolution.height),
                                  fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1]),
                    mapping: CameraTrack.Mapping(frame.worldMappingStatus).label,
                    depth: bytes, depthWidth: CVPixelBufferGetWidth(depth.depthMap),
                    depthHeight: CVPixelBufferGetHeight(depth.depthMap),
                    depthBytesPerRow: CVPixelBufferGetBytesPerRow(depth.depthMap),
                    confidence: confidence,
                    confidenceBytesPerRow: depth.confidenceMap.map(CVPixelBufferGetBytesPerRow))
    }

    private static func copyBytes(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard !CVPixelBufferIsPlanar(buffer), (1...1024).contains(width), (1...1024).contains(height),
              (width * bytesPerPixel...8192).contains(stride), stride * height <= 2 * 1024 * 1024,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return Data(bytes: address, count: stride * height)
    }
}

enum ScanVideoRecordingError: Error, LocalizedError {
    case storageLimit, lowStorage, encoding, storage
    var reason: String {
        switch self {
        case .storageLimit: "storage_limit"
        case .lowStorage: "low_storage"
        case .encoding: "encoding_failed"
        case .storage: "storage_failed"
        }
    }
    var errorDescription: String? {
        switch self {
        case .storageLimit: "Video reached its storage limit. Saved video is kept; scanning can continue."
        case .lowStorage: "Video stopped because storage is low. Saved video is kept; scanning can continue."
        default: "Video stopped. Earlier segments are kept; scanning can continue."
        }
    }
}

/// All encoder and file access is isolated here. RAM holds one copied sample and <=100 poses.
actor ScanVideoWriter {
    struct Policy: Sendable {
        var framesPerSegment = 100
        var maximumDepthBytesPerSegment = 32 * 1024 * 1024
        var maximumRecordedBytes = 2 * 1024 * 1024 * 1024
        var minimumFreeBytes: Int64 = 512 * 1024 * 1024
    }
    private let folder: URL
    private let policy: Policy
    private var manifest: ScanVideoManifest
    private var segment: Segment?
    private var frameCount = 0
    private var recordedBytes = 0
    private var skippedByEncoder = 0
    private var sealed = false
    private var initialized = false
    var isPartial: Bool { manifest.status == "partial" }

    private final class Segment {
        let id: String
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let depthFile: FileHandle
        let width: Int
        let height: Int
        var start: Double
        var depthBytes = 0
        var frames: [ScanVideoFrame] = []
        init(id: String, writer: AVAssetWriter, input: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor, depthFile: FileHandle,
             width: Int, height: Int, start: Double) {
            self.id = id; self.writer = writer; self.input = input; self.adaptor = adaptor
            self.depthFile = depthFile; self.width = width; self.height = height; self.start = start
        }
    }

    init(folder: URL, captureID: String, mapID: String, floorID: String, policy: Policy = .init()) {
        self.folder = folder; self.policy = policy
        manifest = ScanVideoManifest(captureID: captureID, mapID: mapID, floorID: floorID,
            unixOffsetSeconds: Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime,
            status: "recording", segments: [])
    }

    func append(_ sample: ScanVideoSample) async throws -> Int {
        guard !sealed else { return frameCount }
        if !initialized {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: folder.appending(path: "video-manifest.json").path) else {
                throw ScanVideoRecordingError.storage
            }
            try saveManifest()
            initialized = true
        }
        let sampleBytes = sample.depth.count + (sample.confidence?.count ?? 0)
        if let current = segment,
           current.frames.count >= policy.framesPerSegment
            || current.depthBytes + sampleBytes > policy.maximumDepthBytesPerSegment
            || sample.timestamp - current.start >= 10 {
            try await closeSegment()
        }
        if segment == nil {
            try checkCapacity(nextBytes: sampleBytes)
            segment = try makeSegment(sample)
        }
        guard let current = segment else { throw ScanVideoRecordingError.encoding }
        if current.frames.count.isMultiple(of: 20) { try checkCapacity(nextBytes: sampleBytes) }
        guard current.writer.status == .writing else { throw ScanVideoRecordingError.encoding }
        guard current.input.isReadyForMoreMediaData else { skippedByEncoder += 1; return frameCount }
        guard let pool = current.adaptor.pixelBufferPool else { throw ScanVideoRecordingError.encoding }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { skippedByEncoder += 1; return frameCount }
        FrameEncoder.renderSensorVideo(sample.pixels, to: buffer)
        if current.frames.isEmpty { current.start = sample.timestamp }
        let sx = Float(current.width) / Float(sample.camera.imageWidth)
        let sy = Float(current.height) / Float(sample.camera.imageHeight)
        let raw = ScanVideoDepth(width: sample.depthWidth, height: sample.depthHeight,
            bytesPerRow: sample.depthBytesPerRow, pixelFormat: kCVPixelFormatType_DepthFloat32,
            offset: current.depthBytes, length: sample.depth.count,
            confidenceOffset: sample.confidence.map { _ in current.depthBytes + sample.depth.count },
            confidenceLength: sample.confidence?.count, confidenceBytesPerRow: sample.confidenceBytesPerRow)
        let pts = CMTime(seconds: sample.timestamp - current.start, preferredTimescale: 1_000_000)
        let frame = ScanVideoFrame(index: current.frames.count, timestampSeconds: sample.timestamp,
            presentationTimeSeconds: pts.seconds, mapFromCamera: sample.mapFromCamera,
            sensorCamera: sample.camera,
            videoCamera: .init(imageWidth: current.width, imageHeight: current.height,
                fx: sample.camera.fx * sx, fy: sample.camera.fy * sy,
                cx: sample.camera.cx * sx, cy: sample.camera.cy * sy),
            tracking: "normal", mapping: sample.mapping, rawDepth: raw)
        // Validate before either stream commits; a malformed calibration must not be advertised.
        let document = ScanVideoFrameDocument(segmentID: current.id, videoAsset: current.id + ".mp4",
            depthAsset: current.id + ".depth.bin", videoWidth: current.width, videoHeight: current.height,
            frames: current.frames + [frame])
        try document.validate(depthBytes: current.depthBytes + sampleBytes)
        do {
            try current.depthFile.write(contentsOf: sample.depth)
            if let confidence = sample.confidence { try current.depthFile.write(contentsOf: confidence) }
        } catch {
            try? current.depthFile.truncate(atOffset: UInt64(current.depthBytes))
            throw ScanVideoRecordingError.storage
        }
        guard current.adaptor.append(buffer, withPresentationTime: pts) else {
            try current.depthFile.truncate(atOffset: UInt64(current.depthBytes))
            try current.depthFile.seek(toOffset: UInt64(current.depthBytes))
            throw ScanVideoRecordingError.encoding
        }
        current.depthBytes += sampleBytes
        current.frames.append(frame)
        frameCount += 1
        return frameCount
    }

    func finish(reason: String?, skippedSamples: Int) async throws -> Int {
        guard !sealed else { return manifest.segments.reduce(0) { $0 + $1.frameCount } }
        sealed = true
        guard initialized else { return 0 }
        var stopReason = reason
        do { try await closeSegment() }
        catch {
            discardCurrentSegment()
            stopReason = stopReason ?? "segment_finalization_failed"
        }
        if manifest.segments.isEmpty { stopReason = stopReason ?? "no_frames_saved" }
        manifest.status = stopReason == nil ? "complete" : "partial"
        manifest.stopReason = stopReason
        manifest.skippedSamples = skippedSamples + skippedByEncoder
        try saveManifest()
        return manifest.segments.reduce(0) { $0 + $1.frameCount }
    }

    private func makeSegment(_ sample: ScanVideoSample) throws -> Segment {
        let id = String(format: "video-%04d", manifest.segments.count)
        guard let dimensions = Self.videoDimensions(width: sample.camera.imageWidth, height: sample.camera.imageHeight) else {
            throw ScanVideoRecordingError.encoding
        }
        let (width, height) = dimensions
        let videoURL = folder.appending(path: id + ".mp4")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000,
                AVVideoExpectedSourceFrameRateKey: 10, AVVideoMaxKeyFrameIntervalKey: 10,
                AVVideoAllowFrameReorderingKey: false]
        ])
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = 1_000_000
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw ScanVideoRecordingError.encoding }
        writer.add(input)
        guard writer.startWriting() else { throw ScanVideoRecordingError.encoding }
        writer.startSession(atSourceTime: .zero)
        let depthURL = folder.appending(path: id + ".depth.bin")
        guard FileManager.default.createFile(atPath: depthURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            writer.cancelWriting()
            throw ScanVideoRecordingError.storage
        }
        return Segment(id: id, writer: writer, input: input, adaptor: adaptor,
            depthFile: try FileHandle(forWritingTo: depthURL), width: width, height: height, start: sample.timestamp)
    }

    /// Both H.264 dimensions are even without stretching or cropping calibrated pixels.
    nonisolated static func videoDimensions(width: Int, height: Int) -> (Int, Int)? {
        guard width > 0, height > 0 else { return nil }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        let unitWidth = width / a, unitHeight = height / a
        let factor = min(a, 1280 / max(unitWidth, unitHeight)) / 2 * 2
        guard factor > 0 else { return nil }
        return (unitWidth * factor, unitHeight * factor)
    }

    private func closeSegment() async throws {
        guard let current = segment else { return }
        guard !current.frames.isEmpty else { discardCurrentSegment(); return }
        try current.depthFile.synchronize()
        try current.depthFile.close()
        current.input.markAsFinished()
        await current.writer.finishWriting()
        guard current.writer.status == .completed else { throw ScanVideoRecordingError.encoding }
        let document = ScanVideoFrameDocument(segmentID: current.id, videoAsset: current.id + ".mp4",
            depthAsset: current.id + ".depth.bin", videoWidth: current.width, videoHeight: current.height,
            frames: current.frames)
        try document.validate(depthBytes: current.depthBytes)
        let data = try JSONEncoder().encode(document)
        try data.write(to: folder.appending(path: current.id + ".frames.json"), options: .atomic)
        let videoBytes = try folder.appending(path: current.id + ".mp4").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let record = ScanVideoSegment(id: current.id, videoAsset: current.id + ".mp4",
            depthAsset: current.id + ".depth.bin", framesAsset: current.id + ".frames.json",
            videoBytes: videoBytes, depthBytes: current.depthBytes, framesBytes: data.count,
            frameCount: current.frames.count, startTimestampSeconds: current.frames[0].timestampSeconds,
            endTimestampSeconds: current.frames[current.frames.count - 1].timestampSeconds)
        manifest.segments.append(record)
        do { try saveManifest() }
        catch { manifest.segments.removeLast(); throw error }
        recordedBytes += videoBytes + current.depthBytes + data.count
        segment = nil
    }

    private func discardCurrentSegment() {
        guard let current = segment else { return }
        current.writer.cancelWriting()
        try? current.depthFile.close()
        for suffix in [".mp4", ".depth.bin", ".frames.json"] {
            try? FileManager.default.removeItem(at: folder.appending(path: current.id + suffix))
        }
        segment = nil
    }

    private func checkCapacity(nextBytes: Int) throws {
        let activeVideoBytes = segment.flatMap {
            try? folder.appending(path: $0.id + ".mp4").resourceValues(forKeys: [.fileSizeKey]).fileSize
        } ?? 0
        guard recordedBytes + (segment?.depthBytes ?? 0) + activeVideoBytes + nextBytes + 1024 * 1024
                <= policy.maximumRecordedBytes else { throw ScanVideoRecordingError.storageLimit }
        let values = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init)
        if let available, available < policy.minimumFreeBytes + Int64(nextBytes) { throw ScanVideoRecordingError.lowStorage }
    }

    private func saveManifest() throws {
        try manifest.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appending(path: "video-manifest.json"), options: .atomic)
    }
}
