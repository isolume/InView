import AccessCore
import ARKit
import CoreVideo
import Foundation
import simd

/// A copied snapshot, independent of ARKit's mutable Metal and pixel buffers.
struct RawScanSnapshot: Codable, Sendable {
    var meshes: [CaptureMesh]
    var frames: [CaptureDepthFrame]
    var meshBuffers: [RawMeshBuffers]
    var depthBuffers: [RawDepthBuffers]
    var metadata: JSONValue
    /// Compact, confirmed geometry survives depth-keyframe eviction and section changes.
    var observedFootprints: [Footprint]? = nil
}

/// Kept for decoding earlier raw archives; live navigation scans no longer copy mesh buffers.
struct RawMeshBuffers: Codable, Sendable {
    var id: String
    var mapFromAnchor: [Float]
    var vertices: Data
    var vertexOffset: Int
    var vertexStride: Int
    var vertexFormat: UInt
    var vertexCount: Int
    var faces: Data
    var bytesPerIndex: Int
    var faceCount: Int
    var indicesPerFace: Int
    var normals: Data
    var normalOffset: Int
    var normalStride: Int
    var normalFormat: UInt
    var classification: Data?
    var classificationOffset: Int?
    var classificationStride: Int?
}

struct RawDepthBuffers: Codable, Sendable {
    var id: String
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelFormat: UInt32
    var depth: Data
    var confidenceBytesPerRow: Int?
    var confidence: Data?
}

/// Polls the shared RoomPlan session; it never replaces its ARSessionDelegate.
/// RoomPlan supplies the room geometry. Depth is copied into bounded, immutable
/// snapshots before decoding on one background worker; ARFrames and live buffers never escape.
@MainActor
final class RawScanCapture {
    private weak var session: ARSession?
    private var timer: Timer?
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var frames: [CaptureDepthFrame] = []
    private var depthBuffers: [RawDepthBuffers] = []
    private var frameCosts: [Int] = []
    private var lastDepthPosition: SIMD3<Float>?
    private var lastDepthDirection: SIMD3<Float>?
    private var lastDepthTimestamp: TimeInterval?
    private var depthReadFailures = 0
    private var evictedDepthFrames = 0
    private var skippedBusySamples = 0
    private var skippedOversizeSamples = 0
    private var depthEnabled = false
    private let budget = DepthKeyframeBudget()
    private let observedSurfaces = ObservedSurfaceCapture()
    private var smallObstacles = DepthObstacleAccumulator()
    private var lastObstacleTimestamp: TimeInterval?
    private let obstacleInterval: TimeInterval = 1.5
    var floorY: Float?
    var hasObservedFloor: Bool { observedSurfaces.snapshot().contains { $0.kind == .floor } }
    private let pollingInterval: TimeInterval = 0.75
    private let depthInterval: TimeInterval = 2

    /// Call before constructing RoomCaptureView with the custom session. RoomPlan preserves
    /// the supplied world-tracking settings. No reset/remove-anchor options are used.
    func prepare(session: ARSession) {
        let configuration: ARWorldTrackingConfiguration
        if let current = session.configuration {
            guard let world = current.copy() as? ARWorldTrackingConfiguration else { return }
            configuration = world
        } else {
            configuration = ARWorldTrackingConfiguration()
        }
        // Requesting a second raw mesh reconstruction alongside RoomPlan makes work grow with
        // the mapped area. Its structured walls, floors and objects already drive our maps.
        // Preserve any reconstruction setting owned by the supplied session, but add none.
        configuration.planeDetection.formUnion([.horizontal, .vertical])
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        depthEnabled = configuration.frameSemantics.contains(.sceneDepth)
        session.run(configuration, options: [])
    }

    func start(session: ARSession) {
        self.session = session
        resume()
    }

    func resume() {
        guard timer == nil, session != nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        generation += 1
        worker?.cancel()
        // Keep the worker slot occupied until it releases its immutable snapshot. A quick
        // pause/resume cannot queue another allocation behind a worker still finishing.
    }

    func stop() {
        pause()
        session = nil
    }

    /// Finishing can wait for the one copied keyframe without blocking the main actor.
    /// Transfer ownership to the exporter so a scan controller does not retain another copy.
    func finishSnapshot() async -> RawScanSnapshot {
        timer?.invalidate()
        timer = nil
        session = nil
        if let pending = worker { await pending.value }
        let result = snapshot()
        frames.removeAll(keepingCapacity: false)
        depthBuffers.removeAll(keepingCapacity: false)
        frameCosts.removeAll(keepingCapacity: false)
        lastDepthTimestamp = nil
        lastDepthPosition = nil
        lastDepthDirection = nil
        return result
    }

    func snapshot() -> RawScanSnapshot {
        RawScanSnapshot(
            meshes: [], frames: frames, meshBuffers: [], depthBuffers: depthBuffers,
            metadata: .object([
                "status": .string("bounded_depth_keyframes_and_observed_geometry"),
                "mesh_requested": .bool(false),
                "mesh_omission_reason": .string("roomplan_structured_geometry_is_navigation_source"),
                "scene_depth_requested": .bool(depthEnabled),
                "mesh_anchor_count": .number(0),
                "depth_keyframe_count": .number(Double(frames.count)),
                "maximum_depth_keyframes": .number(Double(budget.maximumFrames)),
                "maximum_retained_depth_bytes": .number(Double(budget.maximumRetainedBytes)),
                "maximum_native_depth_frame_bytes": .number(Double(budget.maximumNativeFrameBytes)),
                "depth_keyframe_minimum_interval_seconds": .number(depthInterval),
                "depth_selection": .string("tracking_normal; at_least_2_seconds; translation_0.2m_or_rotation_15deg_or_10_seconds; latest_complete_keyframes_within_memory_budget"),
                "evicted_depth_keyframes": .number(Double(evictedDepthFrames)),
                "skipped_busy_depth_samples": .number(Double(skippedBusySamples)),
                "skipped_oversize_depth_samples": .number(Double(skippedOversizeSamples)),
                "mesh_read_failures": .number(0),
                "depth_read_failures": .number(Double(depthReadFailures)),
                "small_obstacle_interval_seconds": .number(obstacleInterval),
                "small_obstacle_retained_cells": .number(Double(smallObstacles.retainedCellCount)),
                "maximum_small_obstacle_cells": .number(Double(smallObstacles.maximumCells)),
                "maximum_small_obstacle_clusters": .number(Double(smallObstacles.maximumClusters)),
                "small_obstacle_evidence": .string("measured_floor; high_confidence_supported_sides; repeated_frames; floor_ramp_and_near_camera_rejection"),
                "sensor_stream_complete": .bool(false),
                "color_frames_collected": .bool(false),
                "native_buffer_archive": .string("local_only_includes_row_stride_and_original_float_bits"),
            ]), observedFootprints: observedSurfaces.snapshot() + smallObstacles.snapshot()
        )
    }

    private func sample() {
        guard let frame = session?.currentFrame, case .normal = frame.camera.trackingState else { return }
        observedSurfaces.update(frame: frame, floorY: floorY)
        let camera = frame.camera.transform.columns.3
        let measuredFloor = observedSurfaces.floorElevation(near: SIMD3(camera.x, camera.y, camera.z)) ?? floorY
        let keepArchive = shouldKeepDepth(frame)
        let measureObstacles = measuredFloor != nil
            && (lastObstacleTimestamp.map { frame.timestamp - $0 >= obstacleInterval } ?? true)
        guard keepArchive || measureObstacles, let depth = frame.sceneDepth else { return }
        guard worker == nil else {
            skippedBusySamples += 1
            return
        }
        let copied: CopiedDepth
        do {
            var sample = try copyDepth(depth, frame: frame)
            sample.floorY = measuredFloor
            sample.keepsArchive = keepArchive
            copied = sample
        } catch ReadError.exceedsBudget {
            skippedOversizeSamples += 1
            return
        } catch {
            depthReadFailures += 1
            return
        }
        let sampleGeneration = generation
        worker = Task.detached(priority: .utility) { [weak self] in
            let result: DecodeResult
            do {
                var decoded = try Self.decodeDepth(copied)
                if let floorY = copied.floorY {
                    decoded.obstacles = try DepthObstacleEvidence.samples(from: decoded.frame, floorY: floorY)
                }
                result = .success(decoded)
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = .invalid
            }
            await self?.didDecode(result, sample: copied, generation: sampleGeneration)
        }
    }

    private func didDecode(_ result: DecodeResult, sample: CopiedDepth, generation sampleGeneration: Int) {
        worker = nil
        guard sampleGeneration == generation else { return }
        switch result {
        case .success(let decoded):
            if sample.floorY != nil {
                smallObstacles.observe(decoded.obstacles, timestamp: sample.timestamp)
                lastObstacleTimestamp = sample.timestamp
            }
            guard sample.keepsArchive else { return }
            frames.append(decoded.frame)
            depthBuffers.append(decoded.buffer)
            frameCosts.append(sample.cost)
            let removeCount = frames.count - budget.retainedSuffixCount(costs: frameCosts)
            if removeCount > 0 {
                frames.removeFirst(removeCount)
                depthBuffers.removeFirst(removeCount)
                frameCosts.removeFirst(removeCount)
                evictedDepthFrames += removeCount
            }
            lastDepthTimestamp = sample.timestamp
            lastDepthPosition = sample.position
            lastDepthDirection = sample.direction
        case .invalid:
            depthReadFailures += 1
        case .cancelled:
            break
        }
    }

    private func shouldKeepDepth(_ frame: ARFrame) -> Bool {
        guard frame.sceneDepth != nil else { return false }
        guard let timestamp = lastDepthTimestamp, let position = lastDepthPosition,
              let direction = lastDepthDirection else { return true }
        let elapsed = frame.timestamp - timestamp
        guard elapsed >= depthInterval else { return false }
        let camera = frame.camera.transform
        let cameraPosition = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let cameraDirection = SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        return simd_distance(cameraPosition, position) >= 0.2
            || simd_dot(cameraDirection, direction) < cos(Float.pi / 12) || elapsed >= 10
    }

    /// Copy only bounded native bytes while the buffers are locked. All pixel iteration and
    /// portable array allocation happen later; no mutable ARKit object is retained by a task.
    private func copyDepth(_ depth: ARDepthData, frame: ARFrame) throws -> CopiedDepth {
        let buffer = depth.depthMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let confidenceBuffer = depth.confidenceMap
        let confidenceStride = confidenceBuffer.map(CVPixelBufferGetBytesPerRow)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else {
            throw ReadError.unsupportedDepth
        }
        if let confidenceBuffer {
            guard CVPixelBufferGetWidth(confidenceBuffer) == width,
                  CVPixelBufferGetHeight(confidenceBuffer) == height,
                  CVPixelBufferGetPixelFormatType(confidenceBuffer) == kCVPixelFormatType_OneComponent8 else {
                throw ReadError.unsupportedDepth
            }
        }
        guard let cost = budget.frameCost(width: width, height: height, depthBytesPerRow: stride,
                                          confidenceBytesPerRow: confidenceStride) else {
            throw ReadError.exceedsBudget
        }
        let depthBytes = try Self.copyBytes(buffer, count: stride * height)
        let confidenceBytes = try confidenceBuffer.map {
            try Self.copyBytes($0, count: CVPixelBufferGetBytesPerRow($0) * height)
        }
        let calibration = frame.camera.intrinsics
        let image = frame.camera.imageResolution
        let transform = frame.camera.transform
        let raw = RawDepthBuffers(
            id: UUID().uuidString, width: width, height: height, bytesPerRow: stride,
            pixelFormat: CVPixelBufferGetPixelFormatType(buffer), depth: depthBytes,
            confidenceBytesPerRow: confidenceStride, confidence: confidenceBytes
        )
        return CopiedDepth(
            raw: raw, timestamp: frame.timestamp, mapFromCamera: ScanExporter.matrix(transform),
            camera: CaptureCameraCalibration(
                imageWidth: Int(image.width), imageHeight: Int(image.height),
                fx: calibration[0][0], fy: calibration[1][1], cx: calibration[2][0], cy: calibration[2][1]
            ),
            position: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
            direction: SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z), cost: cost
        )
    }

    private nonisolated static func copyBytes(_ buffer: CVPixelBuffer, count: Int) throws -> Data {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ReadError.unsupportedDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { throw ReadError.unsupportedDepth }
        return Data(bytes: pointer, count: count)
    }

    private nonisolated static func decodeDepth(_ sample: CopiedDepth) throws -> DecodedDepth {
        try Task.checkCancellation()
        let raw = sample.raw
        let values: [Float?] = try raw.depth.withUnsafeBytes { bytes in
            var result: [Float?] = []
            result.reserveCapacity(raw.width * raw.height)
            for row in 0..<raw.height {
                try Task.checkCancellation()
                for column in 0..<raw.width {
                    let value = bytes.loadUnaligned(fromByteOffset: row * raw.bytesPerRow + column * 4, as: Float.self)
                    result.append(value.isFinite && value > 0 ? value : nil)
                }
            }
            return result
        }
        var confidence: [Int]?
        if let bytes = raw.confidence, let stride = raw.confidenceBytesPerRow {
            confidence = try bytes.withUnsafeBytes { bytes in
                var result: [Int] = []
                result.reserveCapacity(raw.width * raw.height)
                for row in 0..<raw.height {
                    try Task.checkCancellation()
                    for column in 0..<raw.width {
                        let value = bytes.load(fromByteOffset: row * stride + column, as: UInt8.self)
                        guard value <= 2 else { throw ReadError.unsupportedDepth }
                        result.append(Int(value))
                    }
                }
                return result
            }
        }
        return DecodedDepth(
            frame: CaptureDepthFrame(
                id: raw.id, timestampSeconds: sample.timestamp, mapFromCamera: sample.mapFromCamera,
                camera: sample.camera,
                depth: CaptureDepthImage(width: raw.width, height: raw.height, valuesM: values, confidence: confidence)
            ), buffer: raw
        )
    }

    private struct CopiedDepth: Sendable {
        var raw: RawDepthBuffers
        var timestamp: TimeInterval
        var mapFromCamera: [Float]
        var camera: CaptureCameraCalibration
        var position: SIMD3<Float>
        var direction: SIMD3<Float>
        var cost: Int
        var floorY: Float? = nil
        var keepsArchive = true
    }

    private struct DecodedDepth: Sendable {
        var frame: CaptureDepthFrame
        var buffer: RawDepthBuffers
        var obstacles: [DepthObstacleEvidence.Sample] = []
    }

    private enum DecodeResult: Sendable {
        case success(DecodedDepth)
        case invalid
        case cancelled
    }

    private enum ReadError: Error {
        case unsupportedDepth
        case exceedsBudget
    }
}
