import AccessCore
import ARKit
import CoreVideo
import Foundation
import Metal
import simd

/// A copied snapshot, independent of ARKit's mutable Metal and pixel buffers.
struct RawScanSnapshot: Codable {
    var meshes: [CaptureMesh]
    var frames: [CaptureDepthFrame]
    var meshBuffers: [RawMeshBuffers]
    var depthBuffers: [RawDepthBuffers]
    var metadata: JSONValue
}

/// Native bytes stay local even when their portable JSON layer exceeds the upload limit.
struct RawMeshBuffers: Codable {
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

struct RawDepthBuffers: Codable {
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
@MainActor
final class RawScanCapture {
    private weak var session: ARSession?
    private var timer: Timer?
    private var meshes: [CaptureMesh] = []
    private var meshBuffers: [RawMeshBuffers] = []
    private var frames: [CaptureDepthFrame] = []
    private var depthBuffers: [RawDepthBuffers] = []
    private var lastDepthPose: simd_float4x4?
    private var lastDepthTimestamp: TimeInterval?
    private var meshReadFailures = 0
    private var depthReadFailures = 0
    private var evictedDepthFrames = 0
    private var meshEnabled = false
    private var depthEnabled = false
    private let maximumDepthFrames = 6
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
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        meshEnabled = !configuration.sceneReconstruction.isEmpty
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
        sample()
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        session = nil
    }

    func snapshot() -> RawScanSnapshot {
        RawScanSnapshot(
            meshes: meshes, frames: frames, meshBuffers: meshBuffers, depthBuffers: depthBuffers,
            metadata: .object([
                "status": .string("bounded_keyframes_and_latest_mesh_snapshot"),
                "mesh_requested": .bool(meshEnabled),
                "scene_depth_requested": .bool(depthEnabled),
                "mesh_anchor_count": .number(Double(meshes.count)),
                "depth_keyframe_count": .number(Double(frames.count)),
                "maximum_depth_keyframes": .number(Double(maximumDepthFrames)),
                "depth_keyframe_minimum_interval_seconds": .number(depthInterval),
                "depth_selection": .string("tracking_normal; at_least_2_seconds; translation_0.2m_or_rotation_15deg_or_10_seconds; latest_6"),
                "evicted_depth_keyframes": .number(Double(evictedDepthFrames)),
                "mesh_read_failures": .number(Double(meshReadFailures)),
                "depth_read_failures": .number(Double(depthReadFailures)),
                "sensor_stream_complete": .bool(false),
                "color_frames_collected": .bool(false),
                "native_buffer_archive": .string("local_only_includes_row_stride_and_original_float_bits"),
            ])
        )
    }

    private func sample() {
        guard let frame = session?.currentFrame, case .normal = frame.camera.trackingState else { return }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
            .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
        var currentMeshes: [CaptureMesh] = []
        var currentBuffers: [RawMeshBuffers] = []
        for anchor in anchors {
            do {
                let copied = try copyMesh(anchor)
                currentMeshes.append(copied.0)
                currentBuffers.append(copied.1)
            } catch { meshReadFailures += 1 }
        }
        // ARFrame.anchors describes the current reconstructed snapshot, including removals.
        meshes = currentMeshes
        meshBuffers = currentBuffers
        guard shouldKeepDepth(frame), let depth = frame.sceneDepth else { return }
        do {
            let copied = try copyDepth(depth, frame: frame)
            frames.append(copied.0)
            depthBuffers.append(copied.1)
            lastDepthTimestamp = frame.timestamp
            lastDepthPose = frame.camera.transform
            if frames.count > maximumDepthFrames {
                frames.removeFirst()
                depthBuffers.removeFirst()
                evictedDepthFrames += 1
            }
        } catch { depthReadFailures += 1 }
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
        return distance >= 0.2 || directionDot < cos(Float.pi / 12) || elapsed >= 10
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

    private func copyDepth(_ depth: ARDepthData, frame: ARFrame) throws -> (CaptureDepthFrame, RawDepthBuffers) {
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
                depth: CaptureDepthImage(width: width, height: height, valuesM: values, confidence: confidence)
            ),
            RawDepthBuffers(
                id: id, width: width, height: height, bytesPerRow: stride,
                pixelFormat: CVPixelBufferGetPixelFormatType(buffer), depth: Data(bytes: pointer, count: stride * height),
                confidenceBytesPerRow: confidenceStride, confidence: confidenceBytes
            )
        )
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
