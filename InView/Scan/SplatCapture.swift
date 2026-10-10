import ARKit
import AccessCore
import CoreImage
import Foundation

/// Saves posed camera photos while scanning, so a scan can later be trained into a Gaussian splat: the
/// photoreal look of Apple Maps, as a visual layer over the measured map that routes are planned on.
///
/// Photos go in the capture's `splat` folder beside a `transforms.json` in nerfstudio's format, which OpenSplat
/// and gsplat read directly, and a LiDAR point cloud to start training from. The camera poses are ARKit's, so
/// the trained splat lands in the map's own coordinates and routes line up with it.
@MainActor
final class SplatCapture {
    private weak var session: ARSession?
    private var timer: Timer?
    private let directory: URL?
    private let writer = PhotoWriter()
    private var frames: [Frame] = []
    private var lastPose: simd_float4x4?
    private var isWriting = false

    private static let maximumFrames = 300
    private static let pollingInterval: TimeInterval = 0.4
    /// A new photo once the phone has moved 12 cm or turned 9°, so photos overlap without repeating.
    private static let minimumMove: Float = 0.12
    private static let minimumTurn = cos(Float.pi / 20)
    /// Three quarters of the camera's resolution: detail enough to train on, in about half the space.
    private static let scale: Float = 0.75
    private static let maximumPoints = 100_000

    init(scanID: UUID) {
        directory = try? CaptureStore.splatDirectory(for: scanID.uuidString)
    }

    func start(session: ARSession) {
        self.session = session
        if let directory {
            try? FileManager.default.createDirectory(at: directory.appending(path: "images"), withIntermediateDirectories: true)
        }
        resume()
    }

    func resume() {
        guard timer == nil, session != nil, directory != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        session = nil
    }

    /// Writes `transforms.json` and the starting point cloud, from the scan's LiDAR meshes.
    func finish(meshes: [CaptureMesh]) {
        stop()
        guard let directory, !frames.isEmpty else { return }
        let points = Self.points(from: meshes)
        let transforms = Transforms(frames: frames, plyFilePath: points.isEmpty ? nil : "sparse_pc.ply")
        writer.finish(transforms: transforms, points: points, in: directory)
        Log.scan.info("splat capture: \(self.frames.count) photos, \(points.count) starting points")
    }

    private func sample() {
        guard !isWriting, frames.count < Self.maximumFrames, let directory,
              let frame = session?.currentFrame, case .normal = frame.camera.trackingState else { return }
        let pose = frame.camera.transform
        if let last = lastPose {
            let moved = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
                                      SIMD3(last.columns.3.x, last.columns.3.y, last.columns.3.z))
            let facing = simd_dot(SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z),
                                  SIMD3(last.columns.2.x, last.columns.2.y, last.columns.2.z))
            guard moved >= Self.minimumMove || facing <= Self.minimumTurn else { return }
        }
        lastPose = pose
        isWriting = true
        let path = String(format: "images/frame_%05d.jpg", frames.count + 1)
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        // ARKit's camera is x right, y up, looking down -z: the OpenGL convention nerfstudio expects.
        let record = Frame(filePath: path,
                           transformMatrix: (0..<4).map { row in (0..<4).map { pose[$0][row] } },
                           flX: intrinsics[0][0] * Self.scale, flY: intrinsics[1][1] * Self.scale,
                           cx: intrinsics[2][0] * Self.scale, cy: intrinsics[2][1] * Self.scale,
                           w: Int(Float(resolution.width) * Self.scale), h: Int(Float(resolution.height) * Self.scale))
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(Self.scale), y: CGFloat(Self.scale)))
        writer.write(PhotoWriter.Photo(image: image, url: directory.appending(path: path))) { [weak self] saved in
            Task { @MainActor in
                guard let self else { return }
                self.isWriting = false
                if saved { self.frames.append(record) }
            }
        }
    }

    /// A starting point for training: where the LiDAR mesh is, and its color in the photos.
    struct Seed: Sendable {
        let position: SIMD3<Float>
        /// Packed 0xRRGGBB; mid gray where the mesh has no colors.
        let color: UInt32
    }

    /// LiDAR mesh vertices in map coordinates, thinned evenly to at most `maximumPoints`.
    private static func points(from meshes: [CaptureMesh]) -> [Seed] {
        let total = meshes.reduce(0) { $0 + $1.vertices.count }
        guard total > 0 else { return [] }
        let step = max(1, (total + maximumPoints - 1) / maximumPoints)
        var points: [Seed] = []
        var index = 0
        for mesh in meshes where mesh.mapFromAnchor.count == 16 {
            let m = mesh.mapFromAnchor
            let colors = mesh.colors.flatMap { $0.count == mesh.vertices.count ? $0 : nil }
            for (vertexIndex, vertex) in mesh.vertices.enumerated() where vertex.count == 3 {
                defer { index += 1 }
                guard index.isMultiple(of: step) else { continue }
                points.append(Seed(position: SIMD3(
                    m[0] * vertex[0] + m[4] * vertex[1] + m[8] * vertex[2] + m[12],
                    m[1] * vertex[0] + m[5] * vertex[1] + m[9] * vertex[2] + m[13],
                    m[2] * vertex[0] + m[6] * vertex[1] + m[10] * vertex[2] + m[14]),
                    color: colors?[vertexIndex] ?? 0x808080))
            }
        }
        return points
    }

    struct Frame: Encodable, Sendable {
        let filePath: String
        /// Camera to world, row by row.
        let transformMatrix: [[Float]]
        let flX: Float, flY: Float, cx: Float, cy: Float
        let w: Int, h: Int

        enum CodingKeys: String, CodingKey {
            case filePath = "file_path", transformMatrix = "transform_matrix"
            case flX = "fl_x", flY = "fl_y", cx, cy, w, h
        }
    }

    /// nerfstudio's `transforms.json`. Intrinsics are per photo, and repeated at the top for tools that read them there.
    struct Transforms: Encodable, Sendable {
        let frames: [Frame]
        let plyFilePath: String?

        enum CodingKeys: String, CodingKey {
            case cameraModel = "camera_model", frames, plyFilePath = "ply_file_path"
            case flX = "fl_x", flY = "fl_y", cx, cy, w, h
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode("OPENCV", forKey: .cameraModel)
            if let first = frames.first {
                try values.encode(first.flX, forKey: .flX)
                try values.encode(first.flY, forKey: .flY)
                try values.encode(first.cx, forKey: .cx)
                try values.encode(first.cy, forKey: .cy)
                try values.encode(first.w, forKey: .w)
                try values.encode(first.h, forKey: .h)
            }
            try values.encode(frames, forKey: .frames)
            try values.encodeIfPresent(plyFilePath, forKey: .plyFilePath)
        }
    }
}

/// JPEG encoding and file writes, one at a time, off the main thread.
private final class PhotoWriter: @unchecked Sendable {
    /// A camera image and where it goes. CIImage isn't Sendable; each photo is handed over once and not shared.
    struct Photo: @unchecked Sendable {
        let image: CIImage
        let url: URL
    }

    private let queue = DispatchQueue(label: "inview.splat-capture", qos: .utility)
    private let context = CIContext()

    func write(_ photo: Photo, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [context] in
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
            let saved = (try? context.writeJPEGRepresentation(of: photo.image, to: photo.url,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                               options: options)) != nil
            completion(saved)
        }
    }

    func finish(transforms: SplatCapture.Transforms, points: [SplatCapture.Seed], in directory: URL) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(transforms).write(to: directory.appending(path: "transforms.json"), options: .atomic)
            guard !points.isEmpty else { return }
            // An ASCII PLY of the LiDAR geometry the splat starts from, in the photos' colors.
            var ply = "ply\nformat ascii 1.0\nelement vertex \(points.count)\n"
            ply += "property float x\nproperty float y\nproperty float z\n"
            ply += "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
            for point in points {
                let p = point.position, c = point.color
                ply += "\(p.x) \(p.y) \(p.z) \(c >> 16 & 0xFF) \(c >> 8 & 0xFF) \(c & 0xFF)\n"
            }
            try? Data(ply.utf8).write(to: directory.appending(path: "sparse_pc.ply"), options: .atomic)
        }
    }
}
