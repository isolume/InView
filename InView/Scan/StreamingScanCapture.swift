import AccessCore
import ARKit
import CoreVideo
import Foundation
import simd

/// One copied keyframe at a time. Disk writes finish before the next sample is accepted;
/// upload latency never holds an ARFrame or camera/depth buffer.
@MainActor
final class StreamingScanCapture {
    let queue: StreamingCaptureQueue
    var onStatus: ((StreamingCaptureStatus) -> Void)?
    var onError: ((String) -> Void)?
    var onTrackingHint: ((String?) -> Void)?
    var onCoverage: ((DepthScanCoverageSnapshot) -> Void)?
    var measurements: (() -> [Footprint])?
    /// Geographic/building context (GPS, heading, barometer) for the frame being captured.
    var environment: (() -> CaptureEnvironmentSample?)?
    /// Dense movement poses recorded after the given ARKit time, up to now.
    var movement: ((TimeInterval?) -> [StreamPose])?
    /// Evenly spread streamed keyframes kept for on-device OCR when the scan finishes.
    private(set) var textSources: [TextRecognizer.Source] = []
    private var textSourceSkip = 1
    private var sentMovementThrough: TimeInterval?
    private let maximumTextSources = 48
    private let coverage = SavedScanCoverage()
    private weak var session: ARSession?
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var lastTimestamp: TimeInterval?
    private var lastPose: simd_float4x4?
    private var savedSurfaces: [String: CaptureSurface] = [:]
    private var savedObjects: [String: CaptureObject] = [:]

    init(queue: StreamingCaptureQueue) { self.queue = queue }

    func start(session: ARSession) {
        self.session = session
        resume()
    }

    func resume() {
        guard timer == nil, session != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        // An accepted snapshot still reaches disk when capture is paused.
    }

    func finishCapture() async throws -> StreamingCaptureStatus {
        pause()
        if let worker { await worker.value }
        session = nil
        return try await queue.closeCapture()
    }

    func stop() {
        pause()
        session = nil
        let worker = worker
        let queue = queue
        Task {
            if let worker { await worker.value }
            await queue.stopUploads()
        }
    }

    private func sample() {
        guard let frame = session?.currentFrame else { return }
        switch frame.camera.trackingState {
        case .normal: onTrackingHint?(nil)
        case .limited(.relocalizing):
            onTrackingHint?("Return to an area you've already scanned and look around slowly.")
        case .limited(.excessiveMotion): onTrackingHint?("Move the phone more slowly.")
        default: onTrackingHint?("Point the camera at an area with more detail and good lighting.")
        }
        guard worker == nil, case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1,
              shouldKeep(frame), let depth = frame.sceneDepth,
              let copied = copy(depth: depth, frame: frame),
              let pixels = FrameEncoder.snapshot(frame.capturedImage) else { return }
        let geometry = ScanExporter.streamingMeasurements(measurements?() ?? [])
        // A retained measurement belongs to the pose when it changed, not to every later
        // camera pose. Sending deltas keeps backend label corrections aligned with the mesh.
        let surfaces = geometry.surfaces.filter { savedSurfaces[$0.id] != $0 }
        let objects = geometry.objects.filter { savedObjects[$0.id] != $0 }
        lastTimestamp = frame.timestamp
        lastPose = frame.camera.transform
        let environment = environment?()
        let poses = Array((movement?(sentMovementThrough) ?? []).suffix(StreamChunk.maximumPoses))
        let queue = queue
        let coverage = coverage
        worker = Task { [weak self] in
            do {
                let encoded = try await Task.detached(priority: .utility) {
                    try Self.encode(copied, pixels: pixels)
                }.value
                let status = try await queue.append(frame: encoded.frame, colorJPEG: encoded.jpeg,
                                                    surfaces: surfaces, objects: objects,
                                                    environment: environment, poses: poses)
                if let last = poses.last?.t { self?.sentMovementThrough = last }
                self?.keepTextSource(frameID: encoded.frame.id, sequence: status.captured - 1, jpeg: encoded.jpeg)
                // Green means durably captured on this phone, independent of upload progress.
                let capturedCoverage = await coverage.record(encoded.frame)
                for surface in surfaces { self?.savedSurfaces[surface.id] = surface }
                for object in objects { self?.savedObjects[object.id] = object }
                self?.onCoverage?(capturedCoverage)
                self?.onStatus?(status)
            } catch {
                self?.pause()
                self?.onError?("Couldn't save the scan. \(error.localizedDescription)")
            }
            self?.worker = nil
        }
    }

    /// Keeps every `textSourceSkip`-th keyframe; when full, thins to every other one and doubles the
    /// stride, so the selection stays spread over the whole walk. Names match the backend package
    /// (`s<sequence>.color.jpg`), where the keyframe is stored upright.
    private func keepTextSource(frameID: String, sequence: Int, jpeg: Data) {
        guard sequence % textSourceSkip == 0 else { return }
        textSources.append(TextRecognizer.Source(frameID: frameID, filename: String(format: "s%05d.color.jpg", sequence),
                                                 jpeg: jpeg, sensorNative: true))
        if textSources.count > maximumTextSources {
            textSources = textSources.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
            textSourceSkip *= 2
        }
    }

    private func shouldKeep(_ frame: ARFrame) -> Bool {
        guard let lastTimestamp, let lastPose else { return true }
        let elapsed = frame.timestamp - lastTimestamp
        guard elapsed >= 0.5 else { return false }
        let pose = frame.camera.transform
        return simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
                             SIMD3(lastPose.columns.3.x, lastPose.columns.3.y, lastPose.columns.3.z)) >= 0.1
            || simd_dot(SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z),
                        SIMD3(lastPose.columns.2.x, lastPose.columns.2.y, lastPose.columns.2.z)) < cos(.pi / 18)
            || elapsed >= 3
    }

    private struct Copied: Sendable {
        var id: String
        var timestamp: TimeInterval
        var pose: [Float]
        var camera: CaptureCameraCalibration
        var width: Int
        var height: Int
        var depthStride: Int
        var depth: Data
        var confidenceStride: Int?
        var confidence: Data?
    }

    private func copy(depth: ARDepthData, frame: ARFrame) -> Copied? {
        let buffer = depth.depthMap
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= 512, height <= 512,
              stride >= width * 4, stride * height <= 2 * 1024 * 1024,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              let bytes = Self.copyBytes(buffer, count: stride * height) else { return nil }
        var confidence: Data?
        var confidenceStride: Int?
        if let map = depth.confidenceMap {
            let rowBytes = CVPixelBufferGetBytesPerRow(map)
            guard CVPixelBufferGetWidth(map) == width, CVPixelBufferGetHeight(map) == height,
                  CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent8,
                  rowBytes >= width, rowBytes * height <= 1024 * 1024,
                  let copied = Self.copyBytes(map, count: rowBytes * height) else { return nil }
            confidence = copied
            confidenceStride = rowBytes
        }
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        return Copied(id: UUID().uuidString, timestamp: frame.timestamp,
                      pose: ScanExporter.matrix(frame.camera.transform),
                      camera: CaptureCameraCalibration(imageWidth: Int(resolution.width), imageHeight: Int(resolution.height),
                                                       fx: intrinsics[0][0], fy: intrinsics[1][1],
                                                       cx: intrinsics[2][0], cy: intrinsics[2][1]),
                      width: width, height: height, depthStride: stride, depth: bytes,
                      confidenceStride: confidenceStride, confidence: confidence)
    }

    private nonisolated static func copyBytes(_ buffer: CVPixelBuffer, count: Int) -> Data? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return Data(bytes: address, count: count)
    }

    private nonisolated static func encode(_ sample: Copied, pixels: FrameEncoder.Snapshot) throws -> (frame: CaptureDepthFrame, jpeg: Data) {
        guard let color = FrameEncoder.sensorJPEG(from: pixels) else {
            throw CaptureValidationError.invalid("The camera image could not be saved.")
        }
        let values: [Float?] = sample.depth.withUnsafeBytes { bytes in
            (0..<sample.height).flatMap { row in
                (0..<sample.width).map { column in
                    let value = bytes.loadUnaligned(fromByteOffset: row * sample.depthStride + column * 4, as: Float.self)
                    return value.isFinite && value > 0 && value <= 8 ? value : nil
                }
            }
        }
        let confidence: [Int]? = sample.confidence.flatMap { data in
            guard let stride = sample.confidenceStride else { return nil }
            return data.withUnsafeBytes { bytes in
                (0..<sample.height).flatMap { row in
                    (0..<sample.width).map { column in
                        min(2, Int(bytes.load(fromByteOffset: row * stride + column, as: UInt8.self)))
                    }
                }
            }
        }
        let scaleX = Float(color.width) / Float(sample.camera.imageWidth)
        let scaleY = Float(color.height) / Float(sample.camera.imageHeight)
        let camera = CaptureCameraCalibration(imageWidth: color.width, imageHeight: color.height,
                                              fx: sample.camera.fx * scaleX, fy: sample.camera.fy * scaleY,
                                              cx: sample.camera.cx * scaleX, cy: sample.camera.cy * scaleY)
        return (CaptureDepthFrame(id: sample.id, timestampSeconds: sample.timestamp, mapFromCamera: sample.pose,
                                  camera: camera, depth: CaptureDepthImage(width: sample.width, height: sample.height,
                                                                         valuesM: values, confidence: confidence)), color.jpeg)
    }
}

/// The bounded display index has no camera images and never performs depth work on the UI actor.
private actor SavedScanCoverage {
    private var coverage = DepthScanCoverage()

    func record(_ frame: CaptureDepthFrame) -> DepthScanCoverageSnapshot {
        coverage.recordSavedFrame(frame)
        return coverage.snapshot()
    }
}
