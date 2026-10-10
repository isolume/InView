import AccessCore
import ARKit
import CoreVideo
import Foundation
import Metal
import UIKit
import simd

/// A copied snapshot, independent of ARKit's mutable Metal and pixel buffers.
struct RawScanSnapshot: Codable, Sendable {
    var meshes: [CaptureMesh]
    var frames: [CaptureDepthFrame]
    var meshBuffers: [RawMeshBuffers]
    var depthBuffers: [RawDepthBuffers]
    /// Adaptive RGB keyframes are tied to a calibrated depth-frame ID and encoded off the AR callback.
    var colorKeyframes: [RawColorKeyframe]
    var metadata: JSONValue
    /// High-resolution stills for sign/label OCR, each tied to a retained depth frame (so its pose,
    /// intrinsics, and depth samples exist). Optional so snapshots saved before them still decode.
    var ocrStills: [RawOCRStill]?
    /// Dense ~10 Hz pose track from the same ARSession, staged as `camera-track.json`.
    var cameraTrack: CameraTrack?
}

struct RawColorKeyframe: Codable, Sendable {
    var frameID: String
    var width: Int
    var height: Int
    var jpeg: Data

    var filename: String { "\(frameID).color.jpg" }
}

/// An upright (portrait) JPEG at ≈1920 px, written to a temporary file while scanning so tens of
/// megabytes never sit in memory or get base64-duplicated into `raw-snapshot.json`.
struct RawOCRStill: Codable, Sendable {
    var frameID: String
    var width: Int
    var height: Int
    var bytes: Int
    var temporaryPath: String

    var filename: String { "\(frameID).ocr.jpg" }
}

/// Native bytes stay local even when their portable JSON layer exceeds the upload limit.
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

/// Full-fidelity depth buffers retained locally. `CaptureDepthFrame` remains the bounded portable
/// layer; these original bytes are for export/backend reconstruction and must remain in the same
/// shared ARKit session frame as the RoomPlan result.
struct RawDepthBuffers: Codable, Sendable {
    var id: String
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var pixelFormat: UInt32
    var depth: Data
    var confidenceBytesPerRow: Int?
    var confidence: Data?
    /// ARKit's filtered depth, retained separately so backend processing never has to infer it.
    var smoothedWidth: Int?
    var smoothedHeight: Int?
    var smoothedBytesPerRow: Int?
    var smoothedPixelFormat: UInt32?
    var smoothedDepth: Data?
    /// Coarse location/pressure/heading evidence sampled with this ARKit pose.
    var environment: CaptureEnvironmentSample?
}

/// Polls the shared RoomPlan session; it never replaces its ARSessionDelegate.
@MainActor
final class RawScanCapture {
    private weak var session: ARSession?
    var environmentSampleProvider: (() -> CaptureEnvironmentSample?)?
    private var timer: Timer?
    private var meshes: [CaptureMesh] = []
    private var meshBuffers: [RawMeshBuffers] = []
    /// ARKit updates only the anchors it is actively refining. Keep their latest value by ID so
    /// earlier rooms and dead ends remain represented when the scan continues elsewhere.
    private var meshesByID: [String: CaptureMesh] = [:]
    private var meshBuffersByID: [String: RawMeshBuffers] = [:]
    private var frames: [CaptureDepthFrame] = []
    private var depthBuffers: [RawDepthBuffers] = []
    private var colorKeyframes: [RawColorKeyframe] = []
    private var ocrStills: [RawOCRStill] = []
    /// One in-flight image encode (colour keyframe and/or OCR still from one copied camera image).
    private var imageTask: Task<Void, Never>?
    private let trackRecorder = CameraTrackRecorder()
    private lazy var ocrDirectory = FileManager.default.temporaryDirectory
        .appending(path: "inview-ocr-stills-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var lastDepthPose: simd_float4x4?
    private var lastDepthTimestamp: TimeInterval?
    private var lastColorTimestamp: TimeInterval?
    private var lastStillPose: simd_float4x4?
    private var pendingStillFrameID: String?
    private var lastMeshTimestamp: TimeInterval?
    private var meshReadFailures = 0
    private var depthReadFailures = 0
    private var mappingQualitySkips = 0
    private var evictedDepthFrames = 0
    private var evictedOCRStills = 0
    private var stillEncodeFailures = 0
    private var meshEnabled = false
    private var depthEnabled = false
    private var smoothedDepthEnabled = false
    /// Keep spatially distributed evidence for the full RoomPlan walk, not only its final room.
    /// Native depth stays in the archive; the portable JSON exporter can omit it if necessary.
    ///
    /// Budget (LiDAR 256×192): native raw + confidence + smoothed depth ≈ 192 + 48 + 192 KiB =
    /// 432 KiB per keyframe, colour JPEG ≈ 40–80 KiB, so 48 keyframes ≈ 24 MiB of package sidecars.
    /// Their portable JSON (≈ 0.5 MiB each) is dropped as a whole layer by `ScanExporter` once
    /// `capture.json` would exceed 32 MiB, so that cap holds independently. In memory a keyframe
    /// costs ≈ 1.2 MiB (native bytes + `[Float?]`/`[Int]` portable arrays) ⇒ ≈ 58 MiB at 48.
    /// Package worst case: capture.json 32 + depth 24 + OCR stills 60 + mesh sidecars ≈ 60 +
    /// world map ≈ 30 + RoomPlan ≈ 5 ⇒ ≈ 211 MiB, inside the backend's 256 MiB package limit.
    private let maximumDepthFrames = 48
    /// Pose-space weights: 0.45 m of travel counts like 25° of turn for depth coverage, and
    /// 1.5 m like 30° for OCR stills (signs need new viewpoints more than new pixels).
    private let depthMetersPerRadian: Float = 0.45 / (25 * .pi / 180)
    private let stillMetersPerRadian: Float = 1.5 / (30 * .pi / 180)
    /// A colour keyframe makes a depth frame this many metres "harder" to evict.
    private let colorRetentionBonus: Float = 0.3
    private let pollingInterval: TimeInterval = 0.5
    private let depthInterval: TimeInterval = 1.25
    /// Full mesh-buffer copies are expensive and visibly contend with RoomPlan rendering.
    private let meshInterval: TimeInterval = 3
    /// RGB is evidence for texturing/OCR, not a video recorder. Leave headroom for RoomPlan.
    private let colorInterval: TimeInterval = 3
    /// OCR stills: upright JPEG ≈1920 px q0.85 (≈0.6–1.2 MB). Fewer than `maximumDepthFrames` so
    /// still-carrying frames (protected from eviction) never exhaust the depth budget.
    private let ocrStillMaxDimension: CGFloat = 1920
    private let ocrStillQuality: CGFloat = 0.85
    private let maximumOCRStills = 32
    private let ocrStillByteBudget = 60 * 1024 * 1024
    private let ocrStillMinimumTravel: Float = 1.5
    private let ocrStillMinimumTurn: Float = 30 * .pi / 180

    init() {
        // Stills move into the capture directory when staged; an abandoned scan leaves its
        // temporary directory behind, so remove those left over from earlier sessions.
        Task.detached(priority: .background) { Self.removeStaleOCRDirectories() }
    }

    nonisolated private static func removeStaleOCRDirectories() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        for entry in entries where entry.lastPathComponent.hasPrefix("inview-ocr-stills-") {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }

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
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        // ARKit only fills `smoothedSceneDepth` when it is requested explicitly.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        meshEnabled = !configuration.sceneReconstruction.isEmpty
        depthEnabled = configuration.frameSemantics.contains(.sceneDepth)
        smoothedDepthEnabled = configuration.frameSemantics.contains(.smoothedSceneDepth)
        session.run(configuration, options: [])
    }

    func start(session: ARSession) {
        self.session = session
        resume()
    }

    func resume() {
        guard timer == nil, let session else { return }
        trackRecorder.start(session: session)
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() {
        sample(forceMesh: true)
        trackRecorder.stop()
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        session = nil
    }

    func finalizedSnapshot() async -> RawScanSnapshot {
        await imageTask?.value
        return snapshot()
    }

    func snapshot() -> RawScanSnapshot {
        RawScanSnapshot(
            meshes: meshes, frames: frames, meshBuffers: meshBuffers, depthBuffers: depthBuffers,
            colorKeyframes: colorKeyframes,
            metadata: .object([
                "status": .string("pose_space_coverage_keyframes_ocr_stills_dense_track_and_throttled_mesh_snapshot"),
                "mesh_requested": .bool(meshEnabled),
                "scene_depth_requested": .bool(depthEnabled),
                "smoothed_scene_depth_requested": .bool(smoothedDepthEnabled),
                "mesh_anchor_count": .number(Double(meshes.count)),
                "depth_keyframe_count": .number(Double(frames.count)),
                "maximum_depth_keyframes": .number(Double(maximumDepthFrames)),
                "depth_keyframe_minimum_interval_seconds": .number(depthInterval),
                "depth_selection": .string("tracking_normal; at_least_1.25_seconds; translation_0.45m_or_rotation_25deg_or_12_seconds_or_due_steady_ocr_still; bounded_48_full_walk_coverage"),
                "depth_retention_policy": .string("pose_space_coverage_v1"),
                "depth_retention": .string("evict_min_nearest_neighbor(position_m + 1.03m_per_rad_view_angle); ocr_still_frames_protected_unless_necessary; color_frames_bonus_0.3m"),
                "evicted_depth_keyframes": .number(Double(evictedDepthFrames)),
                "ocr_still_count": .number(Double(ocrStills.count)),
                "ocr_still_bytes": .number(Double(ocrStills.reduce(0) { $0 + $1.bytes })),
                "maximum_ocr_stills": .number(Double(maximumOCRStills)),
                "ocr_still_byte_budget": .number(Double(ocrStillByteBudget)),
                "ocr_still_encoding": .string("upright_portrait_jpeg_max_1920px_q0.85"),
                "ocr_still_selection": .string("tracking_normal; steady_under_0.3rad_s_and_0.6m_s; travel_1.5m_or_turn_30deg_since_last_still; coverage_replacement_at_caps"),
                "evicted_ocr_stills": .number(Double(evictedOCRStills)),
                "ocr_still_encode_failures": .number(Double(stillEncodeFailures)),
                "camera_track_pose_count": .number(Double(trackRecorder.count)),
                "camera_track_rate_hz": .number(1 / trackRecorder.interval),
                "camera_track_decimations": .number(Double(trackRecorder.decimations)),
                "mesh_read_failures": .number(Double(meshReadFailures)),
                "depth_read_failures": .number(Double(depthReadFailures)),
                "mapping_quality_skips": .number(Double(mappingQualitySkips)),
                "raw_capture_quality_gate": .string("world_mapping_extending_or_mapped"),
                "sensor_stream_complete": .bool(false),
                "color_frames_collected": .bool(!colorKeyframes.isEmpty),
                "color_keyframe_count": .number(Double(colorKeyframes.count)),
                "color_keyframe_encoding": .string("adaptive_jpeg_max_640px_3s_throttled"),
                "smoothed_depth_collected": .bool(depthBuffers.contains { $0.smoothedDepth != nil }),
                "environment_sample_count": .number(Double(depthBuffers.filter { $0.environment != nil }.count)),
                "environment_precision": .string("coarse_building_and_floor_context; arkit_pose_is_room_precision"),
                "native_buffer_archive": .string("local_only_includes_raw_and_smoothed_depth_row_strides_original_float_bits_and_confidence"),
            ]),
            ocrStills: ocrStills,
            cameraTrack: trackRecorder.track
        )
    }

    private func sample(forceMesh: Bool = false) {
        guard let frame = session?.currentFrame, case .normal = frame.camera.trackingState else { return }
        guard mappingIsUsable(frame) else {
            mappingQualitySkips += 1
            return
        }
        if forceMesh || lastMeshTimestamp.map({ frame.timestamp - $0 >= meshInterval }) ?? true {
            let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
            for anchor in anchors {
                do {
                    let copied = try copyMesh(anchor)
                    meshesByID[copied.0.id] = copied.0
                    meshBuffersByID[copied.1.id] = copied.1
                } catch { meshReadFailures += 1 }
            }
            meshes = meshesByID.values.sorted { $0.id < $1.id }
            meshBuffers = meshBuffersByID.values.sorted { $0.id < $1.id }
            lastMeshTimestamp = frame.timestamp
        }
        // An OCR still is wanted when the camera has reached a new viewpoint and is held steady.
        // Stills must share a depth frame (pose + intrinsics + depth), so a due still may add a
        // depth keyframe that the motion rule alone would have skipped.
        let wantStill = imageTask == nil && ocrStillIsDue(frame) && trackRecorder.isSteady(at: frame.timestamp)
        let depthSpacingOK = lastDepthTimestamp.map { frame.timestamp - $0 >= depthInterval } ?? true
        guard shouldKeepDepth(frame) || (wantStill && depthSpacingOK), let depth = frame.sceneDepth else { return }
        do {
            let copied = try copyDepth(
                depth, smoothedDepth: frame.smoothedSceneDepth, frame: frame,
                environment: environmentSampleProvider?()
            )
            frames.append(copied.0)
            depthBuffers.append(copied.1)
            let wantColor = lastColorTimestamp.map { frame.timestamp - $0 >= colorInterval } ?? true
            if wantColor || wantStill,
               captureImages(frame.capturedImage, frameID: copied.0.id, pose: frame.camera.transform,
                             color: wantColor, still: wantStill),
               wantColor {
                lastColorTimestamp = frame.timestamp
            }
            lastDepthTimestamp = frame.timestamp
            lastDepthPose = frame.camera.transform
            while frames.count > maximumDepthFrames { evictMostRedundantDepthFrame() }
        } catch { depthReadFailures += 1 }
    }

    /// Drops the depth keyframe whose removal least reduces pose-space coverage (replacing the old
    /// FIFO, which lost the first rooms of long walks). Frames carrying an OCR still are evicted
    /// only if every frame carries one; colour keyframes get a small retention bonus.
    private func evictMostRedundantDepthFrame() {
        let poses = frames.map { CaptureCoverage.Pose(columnMajor: $0.mapFromCamera) ?? CaptureCoverage.Pose(position: .zero, forward: [0, 0, -1]) }
        let stillIDs = Set(ocrStills.map(\.frameID))
        let colorIDs = Set(colorKeyframes.map(\.frameID))
        let frameIDs = frames.map(\.id)
        // A frame whose still is still encoding is protected too: due-still frames sit close to the
        // previous keyframe, so they would otherwise be the first evicted once the budget is full.
        let protected = Set(frameIDs.indices.filter { stillIDs.contains(frameIDs[$0]) || frameIDs[$0] == pendingStillFrameID })
        let bonus = colorRetentionBonus
        let index = CaptureCoverage.mostRedundantIndex(
            poses, metersPerRadian: depthMetersPerRadian, protected: protected,
            retentionBonus: { colorIDs.contains(frameIDs[$0]) ? bonus : 0 }
        ) ?? 0
        let evicted = frames.remove(at: index)
        depthBuffers.removeAll { $0.id == evicted.id }
        colorKeyframes.removeAll { $0.frameID == evicted.id }
        if let still = ocrStills.firstIndex(where: { $0.frameID == evicted.id }) {
            removeStill(at: still)
        }
        evictedDepthFrames += 1
    }

    /// One camera-image copy feeds both encodes. Colour and OCR stills are optional evidence, so
    /// nothing is queued while another encode is still running.
    private func captureImages(_ buffer: CVPixelBuffer, frameID: String, pose: simd_float4x4,
                               color: Bool, still: Bool) -> Bool {
        guard imageTask == nil, let snapshot = FrameEncoder.snapshot(buffer) else { return false }
        var stillURL: URL?
        if still {
            do {
                try FileManager.default.createDirectory(at: ocrDirectory, withIntermediateDirectories: true)
                stillURL = ocrDirectory.appending(path: "\(frameID).ocr.jpg")
                pendingStillFrameID = frameID
            } catch { stillEncodeFailures += 1 }
        }
        let maxDimension = ocrStillMaxDimension, quality = ocrStillQuality
        imageTask = Task { [weak self, stillURL] in
            let encoded = await Task.detached(priority: .utility) { () -> (RawColorKeyframe?, RawOCRStill?) in
                var keyframe: RawColorKeyframe?
                if color, let jpeg = FrameEncoder.portraitJPEG(from: snapshot, maxDimension: 640),
                   let size = FrameEncoder.pixelSize(ofJPEG: jpeg) {
                    keyframe = RawColorKeyframe(frameID: frameID, width: size.width, height: size.height, jpeg: jpeg)
                }
                var ocr: RawOCRStill?
                if let stillURL,
                   let jpeg = FrameEncoder.portraitJPEG(from: snapshot, maxDimension: maxDimension, quality: quality),
                   let size = FrameEncoder.pixelSize(ofJPEG: jpeg),
                   (try? jpeg.write(to: stillURL, options: .atomic)) != nil {
                    ocr = RawOCRStill(frameID: frameID, width: size.width, height: size.height,
                                      bytes: jpeg.count, temporaryPath: stillURL.path)
                }
                return (keyframe, ocr)
            }.value
            guard let self else {
                if let stillURL { try? FileManager.default.removeItem(at: stillURL) }
                return
            }
            defer {
                self.imageTask = nil
                self.pendingStillFrameID = nil
            }
            if stillURL != nil, encoded.1 == nil { self.stillEncodeFailures += 1 }
            guard self.frames.contains(where: { $0.id == frameID }) else {
                // The frame was evicted while encoding; its evidence would have no pose.
                if let stillURL { try? FileManager.default.removeItem(at: stillURL) }
                return
            }
            if let keyframe = encoded.0 {
                self.colorKeyframes.removeAll { $0.frameID == frameID }
                self.colorKeyframes.append(keyframe)
            }
            if let still = encoded.1 {
                // Only a stored still resets the travel/turn spacing; failures retry on the next frame.
                self.lastStillPose = pose
                self.addStill(still)
            }
        }
        return true
    }

    /// Adds a still, then enforces the count and byte caps by removing the most redundant stills in
    /// pose space (possibly the new one), so stills stay spread over the whole walk.
    private func addStill(_ still: RawOCRStill) {
        ocrStills.removeAll { $0.frameID == still.frameID }
        ocrStills.append(still)
        while ocrStills.count > maximumOCRStills || ocrStills.reduce(0, { $0 + $1.bytes }) > ocrStillByteBudget {
            let poses = ocrStills.map(stillPose)
            guard let index = CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: stillMetersPerRadian) else { break }
            removeStill(at: index)
            evictedOCRStills += 1
        }
    }

    private func removeStill(at index: Int) {
        let still = ocrStills.remove(at: index)
        try? FileManager.default.removeItem(atPath: still.temporaryPath)
    }

    private func stillPose(_ still: RawOCRStill) -> CaptureCoverage.Pose {
        frames.first { $0.id == still.frameID }.flatMap { CaptureCoverage.Pose(columnMajor: $0.mapFromCamera) }
            ?? CaptureCoverage.Pose(position: .zero, forward: [0, 0, -1])
    }

    /// A still is due after 1.5 m of travel or a 30° turn since the last one. At a cap it is due
    /// only if it would add more coverage than the most redundant existing still provides.
    private func ocrStillIsDue(_ frame: ARFrame) -> Bool {
        guard depthEnabled else { return false }
        let pose = CaptureCoverage.Pose(mapFromCamera: frame.camera.transform)
        if let last = lastStillPose {
            let previous = CaptureCoverage.Pose(mapFromCamera: last)
            guard simd_distance(pose.position, previous.position) >= ocrStillMinimumTravel
                || CaptureCoverage.viewAngle(pose, previous) >= ocrStillMinimumTurn else { return false }
        }
        let bytes = ocrStills.reduce(0) { $0 + $1.bytes }
        // ≈1 MB headroom for the next still; beyond it, replacement decides.
        if ocrStills.count < maximumOCRStills, bytes + 1_200_000 <= ocrStillByteBudget { return true }
        let poses = ocrStills.map(stillPose)
        guard let index = CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: stillMetersPerRadian) else { return true }
        let others = poses.enumerated().filter { $0.offset != index }.map(\.element)
        let redundancy = CaptureCoverage.nearestDistance(from: poses[index], to: others, metersPerRadian: stillMetersPerRadian)
        return CaptureCoverage.nearestDistance(from: pose, to: poses, metersPerRadian: stillMetersPerRadian) > redundancy
    }

    private func mappingIsUsable(_ frame: ARFrame) -> Bool {
        switch frame.worldMappingStatus {
        case .extending, .mapped: return true
        case .notAvailable, .limited: return false
        @unknown default: return false
        }
    }

    private func shouldKeepDepth(_ frame: ARFrame) -> Bool {
        guard frame.sceneDepth != nil else { return false }
        guard let timestamp = lastDepthTimestamp, let pose = lastDepthPose else { return true }
        let elapsed = frame.timestamp - timestamp
        guard elapsed >= depthInterval else { return false }
        let camera = frame.camera.transform
        let distance = simd_distance(SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z),
                                     SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z))
        let directionDot = simd_dot(SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z),
                                    SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
        return distance >= 0.45 || directionDot < cos(Float.pi / 7.2) || elapsed >= 12
    }

    private func copyMesh(_ anchor: ARMeshAnchor) throws -> (CaptureMesh, RawMeshBuffers) {
        let geometry = anchor.geometry
        let source = geometry.vertices
        let faces = geometry.faces
        guard source.format == .float3, source.componentsPerVector == 3, source.count > 0,
              source.stride >= 12, source.offset >= 0,
              source.offset + (source.count - 1) * source.stride + 12 <= source.buffer.length,
              faces.primitiveType == .triangle, faces.indexCountPerPrimitive == 3,
              faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
              faces.count * 3 * faces.bytesPerIndex <= faces.buffer.length else {
            throw ReadError.unsupportedMesh
        }
        let pointer = source.buffer.contents()
        var vertices: [[Float]] = []
        vertices.reserveCapacity(source.count)
        for index in 0..<source.count {
            let value = pointer.advanced(by: source.offset + source.stride * index)
            let vertex = (0..<3).map { value.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            guard vertex.allSatisfy(\.isFinite) else { throw ReadError.unsupportedMesh }
            vertices.append(vertex)
        }
        let facePointer = faces.buffer.contents()
        var triangles: [[Int]] = []
        triangles.reserveCapacity(faces.count)
        for index in 0..<faces.count {
            let triangle = (0..<3).map { corner -> Int in
                let offset = (index * 3 + corner) * faces.bytesPerIndex
                return faces.bytesPerIndex == 2
                    ? Int(facePointer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    : Int(facePointer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard triangle.allSatisfy({ $0 < source.count }), Set(triangle).count == 3 else {
                throw ReadError.unsupportedMesh
            }
            triangles.append(triangle)
        }
        let classifications: [String]?
        if let classes = geometry.classification {
            guard classes.count == faces.count, classes.format == .uchar,
                  classes.offset + max(0, classes.count - 1) * classes.stride + 1 <= classes.buffer.length else {
                throw ReadError.unsupportedMesh
            }
            classifications = (0..<classes.count).map {
                classification(classes.buffer.contents().load(fromByteOffset: classes.offset + $0 * classes.stride, as: UInt8.self))
            }
        } else { classifications = nil }
        let normals = geometry.normals
        let id = anchor.identifier.uuidString
        let transform = ScanExporter.matrix(anchor.transform)
        return (
            CaptureMesh(id: id, mapFromAnchor: transform, vertices: vertices, triangles: triangles, classifications: classifications),
            RawMeshBuffers(
                id: id, mapFromAnchor: transform,
                vertices: Data(bytes: source.buffer.contents(), count: source.buffer.length),
                vertexOffset: source.offset, vertexStride: source.stride, vertexFormat: source.format.rawValue,
                vertexCount: source.count, faces: Data(bytes: faces.buffer.contents(), count: faces.buffer.length),
                bytesPerIndex: faces.bytesPerIndex, faceCount: faces.count, indicesPerFace: faces.indexCountPerPrimitive,
                normals: Data(bytes: normals.buffer.contents(), count: normals.buffer.length),
                normalOffset: normals.offset, normalStride: normals.stride, normalFormat: normals.format.rawValue,
                classification: geometry.classification.map { Data(bytes: $0.buffer.contents(), count: $0.buffer.length) },
                classificationOffset: geometry.classification?.offset, classificationStride: geometry.classification?.stride
            )
        )
    }

    private func copyDepth(
        _ depth: ARDepthData, smoothedDepth: ARDepthData?, frame: ARFrame,
        environment: CaptureEnvironmentSample?
    ) throws -> (CaptureDepthFrame, RawDepthBuffers) {
        let buffer = depth.depthMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32,
              width > 0, height > 0, stride >= width * 4 else { throw ReadError.unsupportedDepth }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ReadError.unsupportedDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pointer = CVPixelBufferGetBaseAddress(buffer) else { throw ReadError.unsupportedDepth }
        var values: [Float?] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                let value = pointer.loadUnaligned(fromByteOffset: row * stride + column * 4, as: Float.self)
                values.append(value.isFinite && value > 0 ? value : nil)
            }
        }
        var confidence: [Int]?
        var confidenceBytes: Data?
        var confidenceStride: Int?
        if let buffer = depth.confidenceMap {
            guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw ReadError.unsupportedDepth
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ReadError.unsupportedDepth }
            let rowStride = CVPixelBufferGetBytesPerRow(buffer)
            confidence = (0..<(width * height)).map {
                Int(base.load(fromByteOffset: ($0 / width) * rowStride + ($0 % width), as: UInt8.self))
            }
            guard confidence?.allSatisfy({ (0...2).contains($0) }) == true else { throw ReadError.unsupportedDepth }
            confidenceBytes = Data(bytes: base, count: rowStride * height)
            confidenceStride = rowStride
        }
        let smoothed = try smoothedDepth.map(copyOriginalDepthBuffer)
        let calibration = frame.camera.intrinsics
        let image = frame.camera.imageResolution
        let id = UUID().uuidString
        return (
            CaptureDepthFrame(
                id: id, timestampSeconds: frame.timestamp, mapFromCamera: ScanExporter.matrix(frame.camera.transform),
                camera: CaptureCameraCalibration(
                    imageWidth: Int(image.width), imageHeight: Int(image.height),
                    fx: calibration[0][0], fy: calibration[1][1], cx: calibration[2][0], cy: calibration[2][1]
                ),
                depth: CaptureDepthImage(width: width, height: height, valuesM: values, confidence: confidence),
                colorAsset: "\(id).color.jpg"
            ),
            RawDepthBuffers(
                id: id, width: width, height: height, bytesPerRow: stride,
                pixelFormat: CVPixelBufferGetPixelFormatType(buffer), depth: Data(bytes: pointer, count: stride * height),
                confidenceBytesPerRow: confidenceStride, confidence: confidenceBytes,
                smoothedWidth: smoothed?.width, smoothedHeight: smoothed?.height,
                smoothedBytesPerRow: smoothed?.bytesPerRow, smoothedPixelFormat: smoothed?.pixelFormat,
                smoothedDepth: smoothed?.data, environment: environment
            )
        )
    }

    private func copyOriginalDepthBuffer(_ depth: ARDepthData) throws -> (width: Int, height: Int, bytesPerRow: Int, pixelFormat: UInt32, data: Data) {
        let buffer = depth.depthMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        guard pixelFormat == kCVPixelFormatType_DepthFloat32,
              width > 0, height > 0, bytesPerRow >= width * MemoryLayout<Float>.size,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ReadError.unsupportedDepth
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ReadError.unsupportedDepth }
        return (width, height, bytesPerRow, pixelFormat, Data(bytes: base, count: bytesPerRow * height))
    }

    private func classification(_ value: UInt8) -> String {
        switch ARMeshClassification(rawValue: Int(value)) {
        case .wall: "wall"
        case .floor: "floor"
        case .ceiling: "ceiling"
        case .table: "table"
        case .seat: "seat"
        case .window: "window"
        case .door: "door"
        default: "none"
        }
    }

    private enum ReadError: Error {
        case unsupportedMesh
        case unsupportedDepth
    }
}
