import AccessCore
import ARKit
import CoreVideo
import Foundation
import ImageIO
import Metal
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
    /// The mapper's walk is evidence of where to check coverage, never walkable geometry.
    var walkTrace: ScanWalkTrace? = nil
    /// Optional evidence is bounded with its calibrated depth frame and survives offline export.
    var colorKeyframes: [RawColorKeyframe]? = nil
    var cameraTrack: CameraTrack? = nil
}

struct RawColorKeyframe: Codable, Sendable {
    var frameID: String
    var width: Int
    var height: Int
    var jpeg: Data

    var filename: String { "\(frameID).color.jpg" }
}

/// Native mesh buffers are copied once at Finish only when detailed capture was requested.
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
    var environment: CaptureEnvironmentSample? = nil
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
    private var colorKeyframes: [RawColorKeyframe] = []
    private var meshBuffers: [RawMeshBuffers] = []
    private let trackRecorder = CameraTrackRecorder()
    private let contextTracker = CaptureContextTracker()
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
    private let retainsDepthKeyframes: Bool
    private let reconstructsMesh: Bool
    private var meshEnabled = false
    private var omittedMeshAnchors = 0
    private var meshReadFailures = 0
    private static let maximumMeshBytes = 64 * 1024 * 1024
    private static let maximumMeshAnchors = 512
    private let observedSurfaces = ObservedSurfaceCapture()
    private var smallObstacles = DepthObstacleAccumulator()
    private var lastObstacleTimestamp: TimeInterval?
    private let obstacleInterval: TimeInterval = 1.5
    private var walkRecorder = ScanWalkTraceRecorder()
    private var observesFloorOnly = false
    var floorY: Float?
    var hasObservedFloor: Bool { observedSurfaces.snapshot().contains { $0.kind == .floor } }
    /// Pose recording is cheap; floor sampling and depth work keep their own slower limits.
    private let pollingInterval: TimeInterval = 0.25

    /// Continuous capture already archives synchronized depth in its stream. Keep one
    /// fallback observation here, alongside compact measured coverage, instead of copying
    /// and exporting a second depth history when the volunteer finishes.
    init(retainsDepthKeyframes: Bool = true, reconstructsMesh: Bool = false) {
        self.retainsDepthKeyframes = retainsDepthKeyframes
        self.reconstructsMesh = reconstructsMesh
    }
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
        // Detail is a separate, optional display layer. RoomPlan remains the map authority.
        if reconstructsMesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        meshEnabled = reconstructsMesh && !configuration.sceneReconstruction.isEmpty
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
        observesFloorOnly = false
        guard timer == nil, session != nil else { return }
        if let session { trackRecorder.start(session: session) }
        contextTracker.start()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        generation += 1
        trackRecorder.stop()
        contextTracker.stop()
        walkRecorder.suspend()
        worker?.cancel()
        // Keep the worker slot occupied until it releases its immutable snapshot. A quick
        // pause/resume cannot queue another allocation behind a worker still finishing.
    }

    /// Keep measured floor and the walk in the shared frame while RoomPlan processes a
    /// normal doorway handoff. Avoid competing depth allocations during RoomBuilder work.
    func observeFloorDuringHandoff() {
        observesFloorOnly = true
        generation += 1
        worker?.cancel()
    }

    func measuredFloorElevation(near position: SIMD3<Float>) -> Float? {
        observedSurfaces.floorElevation(near: position) ?? floorY.flatMap { $0.isFinite ? $0 : nil }
    }

    func hasMeasuredFloor(at position: SIMD3<Float>) -> Bool {
        observedSurfaces.snapshot().contains {
            $0.kind == .floor && Polygon.contains(SIMD2(position.x, position.z), in: $0.corners)
        }
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
        trackRecorder.stop()
        contextTracker.stop()
        let result = snapshot()
        frames.removeAll(keepingCapacity: false)
        depthBuffers.removeAll(keepingCapacity: false)
        frameCosts.removeAll(keepingCapacity: false)
        colorKeyframes.removeAll(keepingCapacity: false)
        meshBuffers.removeAll(keepingCapacity: false)
        lastDepthTimestamp = nil
        lastDepthPosition = nil
        lastDepthDirection = nil
        return result
    }

    func snapshot() -> RawScanSnapshot {
        RawScanSnapshot(
            meshes: [], frames: frames, meshBuffers: meshBuffers, depthBuffers: depthBuffers,
            metadata: .object([
                "status": .string("bounded_depth_keyframes_and_observed_geometry"),
                "mesh_requested": .bool(reconstructsMesh),
                "mesh_available": .bool(meshEnabled),
                "mesh_omitted_anchor_count": .number(Double(omittedMeshAnchors)),
                "maximum_native_mesh_bytes": .number(Double(Self.maximumMeshBytes)),
                "mesh_role": .string("optional_display_evidence_not_routing_geometry"),
                "scene_depth_requested": .bool(depthEnabled),
                "mesh_anchor_count": .number(Double(meshBuffers.count)),
                "depth_keyframe_count": .number(Double(frames.count)),
                "maximum_depth_keyframes": .number(Double(retainsDepthKeyframes ? budget.maximumFrames : 1)),
                "maximum_retained_depth_bytes": .number(Double(budget.maximumRetainedBytes)),
                "maximum_native_depth_frame_bytes": .number(Double(budget.maximumNativeFrameBytes)),
                "depth_keyframe_minimum_interval_seconds": .number(depthInterval),
                "depth_selection": .string(retainsDepthKeyframes
                    ? "tracking_normal_and_fresh; at_least_2_seconds; pose_space_coverage_within_memory_budget"
                    : "first_complete_fallback_keyframe; synchronized_depth_history_in_stream_archive"),
                "evicted_depth_keyframes": .number(Double(evictedDepthFrames)),
                "skipped_busy_depth_samples": .number(Double(skippedBusySamples)),
                "skipped_oversize_depth_samples": .number(Double(skippedOversizeSamples)),
                "mesh_read_failures": .number(Double(meshReadFailures)),
                "depth_read_failures": .number(Double(depthReadFailures)),
                "small_obstacle_interval_seconds": .number(obstacleInterval),
                "small_obstacle_retained_cells": .number(Double(smallObstacles.retainedCellCount)),
                "maximum_small_obstacle_cells": .number(Double(smallObstacles.maximumCells)),
                "maximum_small_obstacle_clusters": .number(Double(smallObstacles.maximumClusters)),
                "small_obstacle_evidence": .string("measured_floor; high_confidence_supported_sides; repeated_frames; floor_ramp_and_near_camera_rejection"),
                "sensor_stream_complete": .bool(false),
                "color_frames_collected": .bool(!colorKeyframes.isEmpty),
                "color_keyframe_count": .number(Double(colorKeyframes.count)),
                "camera_track_pose_count": .number(Double(trackRecorder.count)),
                "native_buffer_archive": .string("local_only_includes_row_stride_and_original_float_bits"),
            ]), observedFootprints: observedSurfaces.snapshot() + smallObstacles.snapshot(),
            walkTrace: walkRecorder.trace, colorKeyframes: colorKeyframes, cameraTrack: trackRecorder.track
        )
    }

    private func sample() {
        guard let frame = session?.currentFrame else { walkRecorder.suspend(); return }
        let camera = frame.camera.transform.columns.3
        let position = SIMD3(camera.x, camera.y, camera.z)
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        let fresh = abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1
        walkRecorder.record(cameraPosition: position, timestampSeconds: frame.timestamp,
                            trackingIsNormal: normal, frameIsFresh: fresh)
        guard normal, fresh else { return }
        observedSurfaces.update(frame: frame, floorY: floorY)
        guard !observesFloorOnly else { return }
        let measuredFloor = measuredFloorElevation(near: position)
        let keepArchive = retainsDepthKeyframes ? shouldKeepDepth(frame) : frames.isEmpty
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
        // The same copied observation feeds depth and OCR. There is still only one worker,
        // and color is optional when the camera copy or bounded encoding cannot be produced.
        let pixels = keepArchive ? FrameEncoder.snapshot(frame.capturedImage) : nil
        worker = Task.detached(priority: .utility) { [weak self] in
            let result: DecodeResult
            do {
                var decoded = try Self.decodeDepth(copied)
                if let pixels, let jpeg = FrameEncoder.portraitJPEG(from: pixels, maxDimension: 1280),
                   jpeg.count <= 512 * 1024, let size = Self.jpegSize(jpeg) {
                    decoded.color = RawColorKeyframe(frameID: decoded.frame.id,
                                                     width: size.width, height: size.height, jpeg: jpeg)
                    decoded.frame.colorAsset = decoded.color?.filename
                }
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
            if let color = decoded.color { colorKeyframes.append(color) }
            frameCosts.append(sample.cost + (decoded.color?.jpeg.count ?? 0))
            while frames.count > budget.maximumFrames || frameCosts.reduce(0, +) > budget.maximumRetainedBytes {
                let poses = frames.compactMap { CaptureCoverage.Pose(columnMajor: $0.mapFromCamera) }
                let index = poses.count == frames.count
                    ? (CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: 1) ?? 0) : 0
                let removed = frames.remove(at: index)
                depthBuffers.remove(at: index)
                frameCosts.remove(at: index)
                colorKeyframes.removeAll { $0.frameID == removed.id }
                evictedDepthFrames += 1
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

    /// Copies native spans once, before tracking pauses. All allocation limits are checked first.
    func captureReconstructedMesh(from session: ARSession) {
        guard meshEnabled, let frame = session.currentFrame else { return }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
        var copied: [RawMeshBuffers] = []
        var remaining = Self.maximumMeshBytes
        var vertices = 0, faces = 0
        omittedMeshAnchors = 0
        for anchor in anchors {
            guard copied.count < Self.maximumMeshAnchors,
                  anchor.geometry.vertices.count <= ReconstructedMesh.maximumSourceVertices - vertices,
                  anchor.geometry.faces.count <= ReconstructedMesh.maximumSourceTriangles - faces else {
                omittedMeshAnchors += 1
                continue
            }
            guard let buffers = Self.copyMesh(anchor, byteBudget: remaining) else {
                meshReadFailures += 1
                omittedMeshAnchors += 1
                continue
            }
            remaining -= buffers.vertices.count + buffers.normals.count + buffers.faces.count
                + (buffers.classification?.count ?? 0)
            vertices += buffers.vertexCount
            faces += buffers.faceCount
            copied.append(buffers)
        }
        meshBuffers = copied
    }

    private nonisolated static func checkedSpan(offset: Int, count: Int, stride: Int,
                                                elementBytes: Int, available: Int) -> Int? {
        guard offset >= 0, count > 0, stride >= elementBytes, elementBytes > 0,
              available >= offset else { return nil }
        let (span, overflow) = (count - 1).multipliedReportingOverflow(by: stride)
        let (bytes, sumOverflow) = span.addingReportingOverflow(elementBytes)
        guard !overflow, !sumOverflow, bytes <= available - offset else { return nil }
        return bytes
    }

    private static func copyMesh(_ anchor: ARMeshAnchor, byteBudget: Int) -> RawMeshBuffers? {
        let geometry = anchor.geometry
        let vertices = geometry.vertices, normals = geometry.normals, faces = geometry.faces
        guard vertices.format == .float3, normals.format == .float3,
              normals.count == vertices.count, faces.primitiveType == .triangle,
              faces.indexCountPerPrimitive == 3, faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
              let vertexBytes = checkedSpan(offset: vertices.offset, count: vertices.count, stride: vertices.stride,
                                             elementBytes: 12, available: vertices.buffer.length),
              let normalBytes = checkedSpan(offset: normals.offset, count: normals.count, stride: normals.stride,
                                             elementBytes: 12, available: normals.buffer.length),
              let faceBytes = checkedSpan(offset: 0, count: faces.count, stride: 3 * faces.bytesPerIndex,
                                           elementBytes: 3 * faces.bytesPerIndex, available: faces.buffer.length)
        else { return nil }
        let classes = geometry.classification.flatMap { source -> (ARGeometrySource, Int)? in
            guard source.format == .uchar, source.count == faces.count,
                  let bytes = checkedSpan(offset: source.offset, count: source.count, stride: source.stride,
                                          elementBytes: 1, available: source.buffer.length) else { return nil }
            return (source, bytes)
        }
        var remaining = byteBudget
        for count in [vertexBytes, normalBytes, faceBytes, classes?.1 ?? 0] {
            guard count <= remaining else { return nil }
            remaining -= count
        }
        return RawMeshBuffers(
            id: anchor.identifier.uuidString, mapFromAnchor: ScanExporter.matrix(anchor.transform),
            vertices: Data(bytes: vertices.buffer.contents().advanced(by: vertices.offset), count: vertexBytes),
            vertexOffset: 0, vertexStride: vertices.stride, vertexFormat: vertices.format.rawValue,
            vertexCount: vertices.count,
            faces: Data(bytes: faces.buffer.contents(), count: faceBytes),
            bytesPerIndex: faces.bytesPerIndex, faceCount: faces.count, indicesPerFace: 3,
            normals: Data(bytes: normals.buffer.contents().advanced(by: normals.offset), count: normalBytes),
            normalOffset: 0, normalStride: normals.stride, normalFormat: normals.format.rawValue,
            classification: classes.map { Data(bytes: $0.0.buffer.contents().advanced(by: $0.0.offset), count: $0.1) },
            classificationOffset: classes == nil ? nil : 0, classificationStride: classes?.0.stride
        )
    }

    /// Derived detail is built from the already archived native snapshot, off the UI actor.
    nonisolated static func reconstruct(_ snapshot: RawScanSnapshot) throws -> RawScanSnapshot {
        var anchors: [ReconstructedMeshAnchor] = []
        var vertices = 0, faces = 0
        for buffers in snapshot.meshBuffers {
            try Task.checkCancellation()
            guard buffers.vertexCount <= ReconstructedMesh.maximumSourceVertices - vertices,
                  buffers.faceCount <= ReconstructedMesh.maximumSourceTriangles - faces,
                  let anchor = decodeMesh(buffers) else { continue }
            anchors.append(anchor)
            vertices += anchor.vertices.count
            faces += anchor.faces.count
        }
        var result = snapshot
        guard let compacted = try ReconstructedMesh.compact(anchors) else { return result }
        result.meshes = [compacted.mesh]
        if case .object(var metadata) = result.metadata {
            metadata["mesh_source_triangle_count"] = .number(Double(compacted.sourceTriangleCount))
            metadata["mesh_display_triangle_count"] = .number(Double(compacted.mesh.triangles.count))
            metadata["mesh_weld_cell_m"] = .number(Double(compacted.cellSize))
            result.metadata = .object(metadata)
        }
        return result
    }

    private nonisolated static func decodeMesh(_ raw: RawMeshBuffers) -> ReconstructedMeshAnchor? {
        let float3 = MTLVertexFormat.float3.rawValue
        guard raw.mapFromAnchor.count == 16, raw.mapFromAnchor.allSatisfy(\.isFinite),
              raw.vertexFormat == float3, raw.normalFormat == float3,
              raw.vertexCount > 0, raw.vertexCount <= ReconstructedMesh.maximumSourceVertices,
              raw.faceCount > 0, raw.faceCount <= ReconstructedMesh.maximumSourceTriangles,
              checkedSpan(offset: raw.vertexOffset, count: raw.vertexCount, stride: raw.vertexStride,
                          elementBytes: 12, available: raw.vertices.count) != nil,
              checkedSpan(offset: raw.normalOffset, count: raw.vertexCount, stride: raw.normalStride,
                          elementBytes: 12, available: raw.normals.count) != nil,
              raw.indicesPerFace == 3, raw.bytesPerIndex == 2 || raw.bytesPerIndex == 4,
              checkedSpan(offset: 0, count: raw.faceCount, stride: 3 * raw.bytesPerIndex,
                          elementBytes: 3 * raw.bytesPerIndex, available: raw.faces.count) != nil else { return nil }
        func vectors(_ data: Data, offset: Int, stride: Int) -> [SIMD3<Float>] {
            data.withUnsafeBytes { bytes in
                (0..<raw.vertexCount).map { index in
                    let base = offset + index * stride
                    return SIMD3(bytes.loadUnaligned(fromByteOffset: base, as: Float.self),
                                 bytes.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                 bytes.loadUnaligned(fromByteOffset: base + 8, as: Float.self))
                }
            }
        }
        let faces: [SIMD3<UInt32>] = raw.faces.withUnsafeBytes { bytes in
            (0..<raw.faceCount).map { face in
                let corner = { (index: Int) -> UInt32 in
                    let offset = (face * 3 + index) * raw.bytesPerIndex
                    return raw.bytesPerIndex == 2
                        ? UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        : bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                }
                return SIMD3(corner(0), corner(1), corner(2))
            }
        }
        var labels: [String]?
        if let classes = raw.classification, let offset = raw.classificationOffset, let stride = raw.classificationStride,
           checkedSpan(offset: offset, count: raw.faceCount, stride: stride,
                       elementBytes: 1, available: classes.count) != nil {
            labels = (0..<raw.faceCount).map { label(classes[offset + $0 * stride]) }
        }
        let m = raw.mapFromAnchor
        return ReconstructedMeshAnchor(
            mapFromAnchor: simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                         SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])),
            vertices: vectors(raw.vertices, offset: raw.vertexOffset, stride: raw.vertexStride),
            normals: vectors(raw.normals, offset: raw.normalOffset, stride: raw.normalStride),
            faces: faces, labels: labels)
    }

    private nonisolated static func label(_ value: UInt8) -> String {
        switch ARMeshClassification(rawValue: Int(value)) {
        case .wall: "wall"
        case .floor: ReconstructedMesh.floor
        case .ceiling: ReconstructedMesh.ceiling
        case .table: "table"
        case .seat: "seat"
        case .window: "window"
        case .door: "door"
        default: ReconstructedMesh.unlabeled
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
            confidenceBytesPerRow: confidenceStride, confidence: confidenceBytes,
            environment: contextTracker.sample()
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

    private nonisolated static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = values[kCGImagePropertyPixelWidth] as? Int,
              let height = values[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
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
        var color: RawColorKeyframe? = nil
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
