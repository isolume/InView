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

/// ARKit's reconstructed mesh, one anchor's native buffers copied once when a continuous scan
/// finishes. Earlier raw archives also used this shape.
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
    private let retainsDepthKeyframes: Bool
    private let reconstructsMesh: Bool
    private var meshEnabled = false
    private var meshBuffers: [RawMeshBuffers] = []
    private var meshReadFailures = 0
    private var ceilingHint = CeilingCaptureHint()
    private var lastCeilingCheck: TimeInterval?
    private let ceilingCheckInterval: TimeInterval = 1.5
    /// Whether to ask the volunteer to tilt up; continuous scans only.
    var onCeilingHint: ((Bool) -> Void)?
    private let observedSurfaces = ObservedSurfaceCapture()
    private var smallObstacles = DepthObstacleAccumulator()
    private var lastObstacleTimestamp: TimeInterval?
    private let obstacleInterval: TimeInterval = 1.5
    var floorY: Float?
    var hasObservedFloor: Bool { observedSurfaces.snapshot().contains { $0.kind == .floor } }
    private let pollingInterval: TimeInterval = 0.75

    /// Continuous capture already archives synchronized depth in its stream. Keep one
    /// fallback observation here, alongside compact measured coverage, instead of copying
    /// and exporting a second depth history when the volunteer finishes.
    /// - Parameter reconstructsMesh: Continuous scans have no RoomPlan, so ARKit's classified mesh
    ///   is their model of walls, furniture and the ceiling. It's copied once, when the scan finishes.
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
        // Requesting a second raw mesh reconstruction alongside RoomPlan makes work grow with
        // the mapped area. Its structured walls, floors and objects already drive our maps.
        // Preserve any reconstruction setting owned by the supplied session, but add none.
        // Without RoomPlan, ARKit's own fused mesh is what captures walls and ceilings.
        if reconstructsMesh {
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
                configuration.sceneReconstruction = .meshWithClassification
            } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
            }
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
        guard timer == nil, session != nil else { return }
        // Time spent paused isn't time spent scanning without the ceiling.
        ceilingHint = CeilingCaptureHint()
        lastCeilingCheck = nil
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        onCeilingHint?(false)
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
            meshes: [], frames: frames, meshBuffers: meshBuffers, depthBuffers: depthBuffers,
            metadata: .object([
                "status": .string(meshEnabled ? "bounded_depth_keyframes_observed_geometry_and_final_mesh_snapshot"
                                              : "bounded_depth_keyframes_and_observed_geometry"),
                "mesh_requested": .bool(meshEnabled),
                "mesh_omission_reason": meshEnabled ? .null : .string("roomplan_structured_geometry_is_navigation_source"),
                "mesh_selection": meshEnabled ? .string("one_snapshot_when_the_scan_finishes") : .null,
                "scene_depth_requested": .bool(depthEnabled),
                "mesh_anchor_count": .number(Double(meshBuffers.count)),
                "depth_keyframe_count": .number(Double(frames.count)),
                "maximum_depth_keyframes": .number(Double(retainsDepthKeyframes ? budget.maximumFrames : 1)),
                "maximum_retained_depth_bytes": .number(Double(budget.maximumRetainedBytes)),
                "maximum_native_depth_frame_bytes": .number(Double(budget.maximumNativeFrameBytes)),
                "depth_keyframe_minimum_interval_seconds": .number(depthInterval),
                "depth_selection": .string(retainsDepthKeyframes
                    ? "tracking_normal; at_least_2_seconds; translation_0.2m_or_rotation_15deg_or_10_seconds; latest_complete_keyframes_within_memory_budget"
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
                "color_frames_collected": .bool(false),
                "native_buffer_archive": .string("local_only_includes_row_stride_and_original_float_bits"),
            ]), observedFootprints: observedSurfaces.snapshot() + smallObstacles.snapshot()
        )
    }

    private func sample() {
        guard let frame = session?.currentFrame, case .normal = frame.camera.trackingState else { return }
        observedSurfaces.update(frame: frame, floorY: floorY)
        updateCeilingHint(frame)
        let camera = frame.camera.transform.columns.3
        let measuredFloor = observedSurfaces.floorElevation(near: SIMD3(camera.x, camera.y, camera.z)) ?? floorY
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

    /// Copies ARKit's mesh as it stands, once. Only native bytes are copied here; decoding and
    /// welding happen later off the main actor (`reconstruct`).
    func captureReconstructedMesh(from session: ARSession) {
        guard meshEnabled, let frame = session.currentFrame else { return }
        var copied: [RawMeshBuffers] = []
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            if let buffers = Self.copyMesh(anchor) { copied.append(buffers) } else { meshReadFailures += 1 }
        }
        meshBuffers = copied
        Log.scan.notice("copied \(copied.count) reconstructed mesh anchors; \(self.meshReadFailures) unreadable")
    }

    private static func copyMesh(_ anchor: ARMeshAnchor) -> RawMeshBuffers? {
        let geometry = anchor.geometry
        let vertices = geometry.vertices, normals = geometry.normals, faces = geometry.faces
        guard vertices.format == .float3, vertices.count > 0, vertices.stride >= 12,
              vertices.offset + (vertices.count - 1) * vertices.stride + 12 <= vertices.buffer.length,
              normals.format == .float3, normals.count == vertices.count, normals.stride >= 12,
              normals.offset + (normals.count - 1) * normals.stride + 12 <= normals.buffer.length,
              faces.primitiveType == .triangle, faces.indexCountPerPrimitive == 3, faces.count > 0,
              faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
              faces.count * 3 * faces.bytesPerIndex <= faces.buffer.length else { return nil }
        // Labels are optional: a device without classification still yields the mesh.
        let classes = geometry.classification.flatMap { classes -> ARGeometrySource? in
            classes.format == .uchar && classes.count == faces.count
                && classes.offset + (classes.count - 1) * classes.stride + 1 <= classes.buffer.length ? classes : nil
        }
        return RawMeshBuffers(
            id: anchor.identifier.uuidString, mapFromAnchor: ScanExporter.matrix(anchor.transform),
            vertices: Data(bytes: vertices.buffer.contents(), count: vertices.buffer.length),
            vertexOffset: vertices.offset, vertexStride: vertices.stride, vertexFormat: vertices.format.rawValue,
            vertexCount: vertices.count,
            faces: Data(bytes: faces.buffer.contents(), count: faces.buffer.length),
            bytesPerIndex: faces.bytesPerIndex, faceCount: faces.count, indicesPerFace: faces.indexCountPerPrimitive,
            normals: Data(bytes: normals.buffer.contents(), count: normals.buffer.length),
            normalOffset: normals.offset, normalStride: normals.stride, normalFormat: normals.format.rawValue,
            classification: classes.map { Data(bytes: $0.buffer.contents(), count: $0.buffer.length) },
            classificationOffset: classes?.offset, classificationStride: classes?.stride
        )
    }

    /// Decodes the copied mesh and welds it into one labeled display mesh in map coordinates.
    nonisolated static func reconstruct(_ snapshot: RawScanSnapshot) throws -> RawScanSnapshot {
        guard !snapshot.meshBuffers.isEmpty else { return snapshot }
        var anchors: [ReconstructedMeshAnchor] = []
        var unreadable = 0
        for buffers in snapshot.meshBuffers {
            try Task.checkCancellation()
            if let anchor = decodeMesh(buffers) { anchors.append(anchor) } else { unreadable += 1 }
        }
        var result = snapshot
        guard let compacted = try ReconstructedMesh.compact(anchors) else { return result }
        result.meshes = [compacted.mesh]
        if case .object(var metadata) = result.metadata {
            metadata["mesh_source_triangle_count"] = .number(Double(compacted.sourceTriangleCount))
            metadata["mesh_display_triangle_count"] = .number(Double(compacted.mesh.triangles.count))
            metadata["mesh_weld_cell_m"] = .number(Double(compacted.cellSize))
            metadata["mesh_classified"] = .bool(compacted.mesh.classifications != nil)
            metadata["mesh_undecodable_anchors"] = .number(Double(unreadable))
            result.metadata = .object(metadata)
        }
        return result
    }

    private nonisolated static func decodeMesh(_ raw: RawMeshBuffers) -> ReconstructedMeshAnchor? {
        let float3 = MTLVertexFormat.float3.rawValue
        guard raw.mapFromAnchor.count == 16, raw.vertexFormat == float3, raw.normalFormat == float3,
              raw.vertexCount > 0, raw.vertexStride >= 12, raw.normalStride >= 12,
              raw.vertexOffset + (raw.vertexCount - 1) * raw.vertexStride + 12 <= raw.vertices.count,
              raw.normalOffset + (raw.vertexCount - 1) * raw.normalStride + 12 <= raw.normals.count,
              raw.indicesPerFace == 3, raw.bytesPerIndex == 2 || raw.bytesPerIndex == 4,
              raw.faceCount * 3 * raw.bytesPerIndex <= raw.faces.count else { return nil }
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
           offset + (raw.faceCount - 1) * stride + 1 <= classes.count {
            labels = classes.withUnsafeBytes { bytes in
                (0..<raw.faceCount).map { label(bytes.load(fromByteOffset: offset + $0 * stride, as: UInt8.self)) }
            }
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

    /// A phone held level sees the ceiling only at the frame's edge. Every 1.5 s, look in the
    /// mesh anchors around the volunteer for ceiling faces above them.
    private func updateCeilingHint(_ frame: ARFrame) {
        guard meshEnabled, let onCeilingHint,
              lastCeilingCheck.map({ frame.timestamp - $0 >= ceilingCheckInterval }) ?? true else { return }
        lastCeilingCheck = frame.timestamp
        let camera = frame.camera.transform
        let position = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        // ARKit cameras look along -z; more than 35° above level counts as looking up.
        let lookingUp = -camera.columns.2.y > sin(Float.pi * 35 / 180)
        let shown = ceilingHint.update(time: frame.timestamp, position: position, lookingUp: lookingUp,
                                       ceilingNearby: Self.ceilingNearby(frame, camera: position))
        onCeilingHint(shown)
    }

    /// Whether ARKit has ceiling faces within 2 m (in plan) above the camera. Reads the
    /// labels of at most 24 nearby anchors, and a vertex only for faces labeled ceiling.
    private static func ceilingNearby(_ frame: ARFrame, camera: SIMD3<Float>) -> Bool {
        let reach: Float = 2
        func plan(_ point: SIMD4<Float>) -> Float { simd_distance(SIMD2(point.x, point.z), SIMD2(camera.x, camera.z)) }
        let nearby = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            .map { (anchor: $0, distance: plan($0.transform.columns.3)) }
            .filter { $0.distance < 6 }
            .sorted { $0.distance < $1.distance }
            .prefix(24)
        let ceiling = UInt8(ARMeshClassification.ceiling.rawValue)
        for (anchor, _) in nearby {
            let geometry = anchor.geometry
            let vertices = geometry.vertices, faces = geometry.faces
            guard let classes = geometry.classification, classes.format == .uchar, classes.count == faces.count,
                  classes.count > 0, classes.offset + (classes.count - 1) * classes.stride + 1 <= classes.buffer.length,
                  vertices.format == .float3, vertices.count > 0,
                  vertices.offset + (vertices.count - 1) * vertices.stride + 12 <= vertices.buffer.length,
                  faces.indexCountPerPrimitive == 3, faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
                  faces.count * 3 * faces.bytesPerIndex <= faces.buffer.length else { continue }
            let labels = classes.buffer.contents(), corners = faces.buffer.contents(), points = vertices.buffer.contents()
            for face in 0..<classes.count where labels.load(fromByteOffset: classes.offset + face * classes.stride, as: UInt8.self) == ceiling {
                let index = faces.bytesPerIndex == 2
                    ? Int(corners.loadUnaligned(fromByteOffset: face * 3 * 2, as: UInt16.self))
                    : Int(corners.loadUnaligned(fromByteOffset: face * 3 * 4, as: UInt32.self))
                guard index < vertices.count else { continue }
                let base = vertices.offset + index * vertices.stride
                let local = SIMD4(points.loadUnaligned(fromByteOffset: base, as: Float.self),
                                  points.loadUnaligned(fromByteOffset: base + 4, as: Float.self),
                                  points.loadUnaligned(fromByteOffset: base + 8, as: Float.self), 1)
                let world = anchor.transform * local
                if world.y > camera.y + 0.3, plan(world) <= reach { return true }
            }
        }
        return false
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
