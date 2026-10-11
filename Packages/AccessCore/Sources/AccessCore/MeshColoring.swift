import Foundation
import simd

/// A decoded camera photo: 8-bit RGBA rows from top to bottom, with an explicit saved orientation.
public struct ColorImage: Sendable {
    public enum Orientation: Equatable, Sendable { case sensorNative, portraitClockwise }
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]
    public let orientation: Orientation

    public init?(width: Int, height: Int, rgba: [UInt8], orientation: Orientation = .sensorNative) {
        guard (1...4_096).contains(width), (1...4_096).contains(height),
              rgba.count == width * height * 4 else { return nil }
        self.width = width; self.height = height; self.rgba = rgba
        self.orientation = orientation
    }

    /// Bilinear sample at normalized sensor coordinates, 0–1 per channel. The canonical
    /// scanner saves upright photos rotated clockwise from the calibrated sensor image.
    func color(at sensorUV: SIMD2<Float>) -> SIMD3<Float> {
        let uv = orientation == .portraitClockwise ? SIMD2(1 - sensorUV.y, sensorUV.x) : sensorUV
        let x = min(max(uv.x * Float(width) - 0.5, 0), Float(width - 1))
        let y = min(max(uv.y * Float(height) - 0.5, 0), Float(height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        func pixel(_ column: Int, _ row: Int) -> SIMD3<Float> {
            let offset = (row * width + column) * 4
            return SIMD3(Float(rgba[offset]), Float(rgba[offset + 1]), Float(rgba[offset + 2])) / 255
        }
        let top = pixel(x0, y0) * (1 - fx) + pixel(x1, y0) * fx
        let bottom = pixel(x0, y1) * (1 - fx) + pixel(x1, y1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// Colors a mesh from posed photos with measured depth, the way a 3D scanning app does. Each vertex
/// blends the photos that saw it head-on and up close; a photo where measured depth says something
/// stood in front of the vertex is left out, so a chair isn't painted onto the wall behind it.
public struct MeshColoring: Sendable {
    /// Unseen vertices take this, after borrowing from seen neighbors runs out.
    public static let fallback: UInt32 = 0xC9CDCA
    /// A fixed CPU budget shared by every photo, including photos that color no vertices.
    public static let maximumVertexVisits = 20_000_000
    public static let maximumPhotos = 200

    public static func photoLimit(vertexCount: Int) -> Int {
        guard (1...ReconstructedMesh.maximumVertices).contains(vertexCount) else { return 0 }
        return min(maximumPhotos, maximumVertexVisits / vertexCount)
    }
    /// Beyond this, LiDAR depth and photo detail are too coarse to trust.
    static let maximumDistance: Float = 5
    /// Faces seen this obliquely smear one pixel across many vertices.
    static let minimumFacing: Float = 0.25

    private let positions: [SIMD3<Float>]
    private let normals: [SIMD3<Float>]
    private let triangles: [SIMD3<Int>]
    private var sums: [SIMD3<Float>]
    private var weights: [Float]
    private var remainingVertexVisits: Int
    /// Photos that colored at least one vertex.
    public private(set) var observationsUsed = 0

    /// - Parameter mesh: A mesh whose faces are wound towards the side the sensor saw, like
    ///   `ReconstructedMesh`'s, so its normals say which photos looked at the front.
    public init?(mesh: CaptureMesh, maximumVertexVisits: Int = MeshColoring.maximumVertexVisits) {
        let m = mesh.mapFromAnchor
        guard !Task.isCancelled, validRigidTransform(m), !mesh.vertices.isEmpty,
              mesh.vertices.count <= ReconstructedMesh.maximumVertices,
              mesh.triangles.count <= ReconstructedMesh.defaultTriangleTarget,
              mesh.vertices.allSatisfy(validVector) else { return nil }
        let positions = mesh.vertices.map { v in
            SIMD3(m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12],
                  m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13],
                  m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14])
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
            && simd_reduce_max(simd_abs($0)) < 10_000 }) else { return nil }
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var triangles: [SIMD3<Int>] = []
        triangles.reserveCapacity(mesh.triangles.count)
        for face in mesh.triangles where face.count == 3 && face.allSatisfy({ positions.indices.contains($0) }) {
            let a = positions[face[0]], b = positions[face[1]], c = positions[face[2]]
            let normal = simd_cross(b - a, c - a)
            for index in face { normals[index] += normal }
            triangles.append(SIMD3(face[0], face[1], face[2]))
        }
        self.positions = positions
        self.normals = normals.map { simd_length_squared($0) > 1e-12 ? simd_normalize($0) : .zero }
        self.triangles = triangles
        sums = Array(repeating: .zero, count: positions.count)
        weights = Array(repeating: 0, count: positions.count)
        remainingVertexVisits = min(Self.maximumVertexVisits, max(0, maximumVertexVisits))
    }

    /// Share of vertices at least one photo colored.
    public var coverage: Float {
        Float(weights.lazy.filter { $0 > 0 }.count) / Float(max(1, weights.count))
    }

    /// Adds one photo. `frame`'s calibration and depth describe the same normalized image as `image`.
    public mutating func add(frame: CaptureDepthFrame, image: ColorImage) throws {
        try Task.checkCancellation()
        let values = frame.mapFromCamera, camera = frame.camera, depth = frame.depth
        let count = depth.width.multipliedReportingOverflow(by: depth.height)
        guard validRigidTransform(values), frame.pixelOrientation == "sensor_native",
              camera.imageWidth > 0, camera.imageHeight > 0, camera.fx > 0, camera.fy > 0,
              [camera.fx, camera.fy, camera.cx, camera.cy].allSatisfy(\.isFinite),
              depth.width > 0, depth.height > 0, !count.overflow, depth.valuesM.count == count.partialValue,
              depth.confidence.map({ $0.count == depth.valuesM.count }) ?? true else { return }
        guard positions.count <= remainingVertexVisits else {
            throw CaptureValidationError.invalid("The scan detail reached its photo limit.")
        }
        remainingVertexVisits -= positions.count
        let mapFromCamera = simd_float4x4(SIMD4(values[0], values[1], values[2], values[3]),
                                          SIMD4(values[4], values[5], values[6], values[7]),
                                          SIMD4(values[8], values[9], values[10], values[11]),
                                          SIMD4(values[12], values[13], values[14], values[15]))
        let cameraFromMap = mapFromCamera.inverse
        let eye = SIMD3(values[12], values[13], values[14])
        let width = Float(camera.imageWidth), height = Float(camera.imageHeight)
        var used = false
        for index in positions.indices {
            if index % 16_384 == 0 { try Task.checkCancellation() }
            let local = cameraFromMap * SIMD4(positions[index], 1)
            // ARKit cameras look along -z, with image y down and camera y up.
            let distance = -local.z
            guard distance > 0.15, distance < Self.maximumDistance else { continue }
            let uv = SIMD2((camera.fx * local.x / distance + camera.cx) / width,
                           (camera.cy - camera.fy * local.y / distance) / height)
            guard uv.x >= 0, uv.x < 1, uv.y >= 0, uv.y < 1 else { continue }
            let sample = min(Int(uv.y * Float(depth.height)), depth.height - 1) * depth.width
                + min(Int(uv.x * Float(depth.width)), depth.width - 1)
            // Depth is distance along the optical axis, like `distance`. Welding moves vertices a few
            // centimeters off the measured surface, so allow for that and for depth noise at range.
            guard let measured = depth.valuesM[sample], measured.isFinite,
                  abs(measured - distance) <= 0.06 + 0.03 * distance,
                  (depth.confidence?[sample] ?? 1) >= 1 else { continue }
            let facing = simd_dot(normals[index], simd_normalize(eye - positions[index]))
            guard facing > Self.minimumFacing else { continue }
            // Head-on and close views are sharpest; image edges are softer and vignetted.
            let edge = min(1, 10 * min(min(uv.x, 1 - uv.x), min(uv.y, 1 - uv.y)))
            let near = max(distance, 0.5)
            let weight = facing * facing * facing * facing * edge / (near * near)
            guard weight > 0 else { continue }
            sums[index] += weight * image.color(at: uv)
            weights[index] += weight
            used = true
        }
        if used { observationsUsed += 1 }
    }

    /// Packed 0xRRGGBB per vertex. Vertices no photo saw borrow from seen neighbors, up to
    /// `fillingRings` edges away; any left take `fallback`.
    public func colors(fillingRings: Int = 4) throws -> [UInt32] {
        try Task.checkCancellation()
        var colors: [SIMD3<Float>?] = []
        colors.reserveCapacity(sums.count)
        for index in sums.indices {
            if index % 16_384 == 0 { try Task.checkCancellation() }
            colors.append(weights[index] > 0 ? sums[index] / weights[index] : nil)
        }
        for _ in 0..<min(4, max(0, fillingRings)) {
            try Task.checkCancellation()
            var borrowed = [SIMD3<Float>](repeating: .zero, count: colors.count)
            var counts = [Float](repeating: 0, count: colors.count)
            for (index, face) in triangles.enumerated() {
                if index % 16_384 == 0 { try Task.checkCancellation() }
                for (vertex, other) in [(face.x, face.y), (face.x, face.z), (face.y, face.x),
                                        (face.y, face.z), (face.z, face.x), (face.z, face.y)] {
                    guard colors[vertex] == nil, let color = colors[other] else { continue }
                    borrowed[vertex] += color
                    counts[vertex] += 1
                }
            }
            var filled = false
            for index in colors.indices where colors[index] == nil && counts[index] > 0 {
                colors[index] = borrowed[index] / counts[index]
                filled = true
            }
            if !filled { break }
        }
        return try colors.enumerated().map { index, color in
            if index % 16_384 == 0 { try Task.checkCancellation() }
            guard let color else { return Self.fallback }
            let bytes = simd_clamp(color, .zero, SIMD3(repeating: 1)) * 255
            return UInt32(bytes.x.rounded()) << 16 | UInt32(bytes.y.rounded()) << 8 | UInt32(bytes.z.rounded())
        }
    }
}
