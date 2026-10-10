import Foundation
import simd

/// One chunk of ARKit's scene reconstruction, copied out of its Metal buffers.
/// Positions and normals are local to the anchor; `labels` has one entry per face.
public struct ReconstructedMeshAnchor: Sendable, Equatable {
    public var mapFromAnchor: simd_float4x4
    public var vertices: [SIMD3<Float>]
    /// Empty when the anchor supplied none; otherwise one per vertex, pointing to the observed side.
    public var normals: [SIMD3<Float>]
    public var faces: [SIMD3<UInt32>]
    public var labels: [String]?

    public init(mapFromAnchor: simd_float4x4, vertices: [SIMD3<Float>], normals: [SIMD3<Float>] = [],
                faces: [SIMD3<UInt32>], labels: [String]? = nil) {
        self.mapFromAnchor = mapFromAnchor; self.vertices = vertices; self.normals = normals
        self.faces = faces; self.labels = labels
    }
}

/// ARKit fuses every LiDAR frame into one classified mesh, so surfaces seen only at grazing angles,
/// like a ceiling while the phone faces forward, still fill in. This merges its anchors into one
/// welded display mesh in map coordinates and measures the ceiling from the faces ARKit labels.
public enum ReconstructedMesh {
    /// Identifies the merged mesh in captures and scenes.
    public static let sourceID = "arkit-scene-mesh"
    public static let ceiling = "ceiling"
    public static let floor = "floor"
    public static let unlabeled = "none"
    /// Enough for a detailed floor while keeping saved scenes and SceneKit geometry small.
    public static let defaultTriangleTarget = 150_000
    /// Welding starts at 2 cm, like the backend's depth fusion, and coarsens until the mesh fits.
    static let cellSizes: [Float] = [0.02, 0.04, 0.08, 0.16]
    /// Larger coordinates are not plausible indoor measurements and would overflow the weld grid.
    private static let coordinateLimit: Float = 10_000

    public struct Compacted: Sendable, Equatable {
        public var mesh: CaptureMesh
        /// The weld cell that brought the mesh within its triangle target.
        public var cellSize: Float
        public var sourceTriangleCount: Int
    }

    /// Merges anchors into one mesh with an identity pose. Faces keep ARKit's label and are wound
    /// counterclockwise towards the observed side, so single-sided rendering hides back faces.
    public static func compact(_ anchors: [ReconstructedMeshAnchor],
                               triangleTarget: Int = defaultTriangleTarget) throws -> Compacted? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var faces: [SIMD3<Int>] = []
        var labels: [String] = []
        let labeled = anchors.contains { $0.labels != nil }
        for anchor in anchors {
            try Task.checkCancellation()
            guard anchor.normals.isEmpty || anchor.normals.count == anchor.vertices.count,
                  anchor.labels == nil || anchor.labels?.count == anchor.faces.count else { continue }
            let m = anchor.mapFromAnchor
            let rotation = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                         SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                         SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            // A vertex that can't be placed invalidates only the faces that use it.
            var local = [Int](repeating: -1, count: anchor.vertices.count)
            for (index, vertex) in anchor.vertices.enumerated() {
                let world = m * SIMD4(vertex, 1)
                let point = SIMD3(world.x, world.y, world.z)
                guard point.x.isFinite, point.y.isFinite, point.z.isFinite,
                      simd_reduce_max(simd_abs(point)) < coordinateLimit else { continue }
                local[index] = positions.count
                positions.append(point)
                let normal = anchor.normals.isEmpty ? .zero : rotation * anchor.normals[index]
                normals.append(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite ? normal : .zero)
            }
            for (index, face) in anchor.faces.enumerated() {
                guard Int(face.x) < local.count, Int(face.y) < local.count, Int(face.z) < local.count else { continue }
                let mapped = SIMD3(local[Int(face.x)], local[Int(face.y)], local[Int(face.z)])
                guard mapped.x >= 0, mapped.y >= 0, mapped.z >= 0 else { continue }
                faces.append(mapped)
                labels.append(anchor.labels?[index] ?? unlabeled)
            }
        }
        guard !faces.isEmpty else { return nil }
        for (level, cell) in cellSizes.enumerated() {
            try Task.checkCancellation()
            let mesh = try weld(positions: positions, normals: normals, faces: faces, labels: labels, cell: cell)
            if mesh.triangles.count <= triangleTarget || level == cellSizes.count - 1 {
                guard !mesh.triangles.isEmpty else { return nil }
                var result = mesh
                if !labeled { result.classifications = nil }
                return Compacted(mesh: result, cellSize: cell, sourceTriangleCount: faces.count)
            }
        }
        return nil
    }

    /// Vertex clustering: every vertex moves to the mean of its cell; faces that collapse are removed,
    /// and a face seen from overlapping anchors is kept once.
    private static func weld(positions: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [SIMD3<Int>],
                             labels: [String], cell: Float) throws -> CaptureMesh {
        var clusters: [SIMD3<Int32>: Int] = [:]
        clusters.reserveCapacity(positions.count / 2)
        var clusterOf = [Int](repeating: 0, count: positions.count)
        var sums: [SIMD3<Float>] = []
        var counts: [Float] = []
        for (index, point) in positions.enumerated() {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            let scaled = (point / cell).rounded(.down)
            let key = SIMD3(Int32(scaled.x), Int32(scaled.y), Int32(scaled.z))
            if let cluster = clusters[key] {
                clusterOf[index] = cluster
                sums[cluster] += point
                counts[cluster] += 1
            } else {
                clusters[key] = sums.count
                clusterOf[index] = sums.count
                sums.append(point)
                counts.append(1)
            }
        }
        let centers = zip(sums, counts).map { $0 / $1 }
        var seen = Set<SIMD3<Int>>()
        var used = [Int](repeating: -1, count: centers.count)
        var vertices: [[Float]] = []
        var triangles: [[Int]] = []
        var classifications: [String] = []
        for (index, face) in faces.enumerated() {
            if index % 65_536 == 0 { try Task.checkCancellation() }
            var a = clusterOf[face.x], b = clusterOf[face.y], c = clusterOf[face.z]
            guard a != b, b != c, a != c else { continue }
            let sorted = [a, b, c].sorted()
            guard seen.insert(SIMD3(sorted[0], sorted[1], sorted[2])).inserted else { continue }
            let normal = simd_cross(centers[b] - centers[a], centers[c] - centers[a])
            guard simd_length_squared(normal) > 1e-12 else { continue }
            // Wind towards ARKit's normals, which point to the side the sensor saw.
            let observed = normals[face.x] + normals[face.y] + normals[face.z]
            if simd_dot(normal, observed) < 0 { swap(&b, &c) }
            let corners = [a, b, c].map { cluster -> Int in
                if used[cluster] < 0 {
                    used[cluster] = vertices.count
                    let center = centers[cluster]
                    vertices.append([center.x, center.y, center.z])
                }
                return used[cluster]
            }
            triangles.append(corners)
            classifications.append(labels[index])
        }
        return CaptureMesh(id: sourceID, mapFromAnchor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                           vertices: vertices, triangles: triangles, classifications: classifications)
    }
}

/// How high the ceiling is and how much of it the scan captured, from ARKit's labeled faces.
public struct CeilingMeasurement: Codable, Equatable, Sendable {
    /// Median height of the ceiling above the floor beneath it, in meters.
    public var heightM: Float
    /// Median ceiling elevation in map coordinates.
    public var elevation: Float
    /// Share of measured floor that has captured ceiling above it, 0–1. Nil when no floor was labeled.
    public var floorCoverage: Float?
    /// Plan area of captured ceiling, in square meters.
    public var areaM2: Float

    public init(heightM: Float, elevation: Float, floorCoverage: Float?, areaM2: Float) {
        self.heightM = heightM; self.elevation = elevation; self.floorCoverage = floorCoverage; self.areaM2 = areaM2
    }

    enum CodingKeys: String, CodingKey {
        case heightM = "height_m", elevation, floorCoverage = "floor_coverage", areaM2 = "area_m2"
    }

    /// Ceilings are compared with floors on a plan grid of this size.
    static let cell: Float = 0.25
    /// Lower than a doorway or higher than a tall atrium is a mislabeled surface, not this room's ceiling.
    static let plausibleHeights: ClosedRange<Float> = 1.9...8

    /// - Parameter floorY: The map's floor, used where ARKit labeled ceiling but no floor below it.
    public static func measure(_ mesh: CaptureMesh, floorY: Float?) -> CeilingMeasurement? {
        guard let labels = mesh.classifications, labels.count == mesh.triangles.count else { return nil }
        let mapFromAnchor = mesh.mapFromAnchor
        guard mapFromAnchor.count == 16 else { return nil }
        func point(_ index: Int) -> SIMD3<Float>? {
            guard mesh.vertices.indices.contains(index), mesh.vertices[index].count == 3 else { return nil }
            let v = mesh.vertices[index], m = mapFromAnchor
            return SIMD3(m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12],
                         m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13],
                         m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14])
        }
        // Area-weighted mean height of each kind of horizontal surface, per plan cell.
        var floors: [SIMD2<Int32>: SIMD2<Float>] = [:]
        var ceilings: [SIMD2<Int32>: SIMD2<Float>] = [:]
        for (index, triangle) in mesh.triangles.enumerated() {
            let label = labels[index]
            guard label == ReconstructedMesh.ceiling || label == ReconstructedMesh.floor, triangle.count == 3,
                  let a = point(triangle[0]), let b = point(triangle[1]), let c = point(triangle[2]) else { continue }
            let cross = simd_cross(b - a, c - a)
            let area = simd_length(cross) / 2
            // ARKit sometimes labels the top of a wall as ceiling; only near-horizontal faces count.
            guard area > 1e-6, area.isFinite, abs(cross.y) / (2 * area) > 0.8 else { continue }
            let center = (a + b + c) / 3
            let key = SIMD2(Int32((center.x / cell).rounded(.down)), Int32((center.z / cell).rounded(.down)))
            let weighted = SIMD2(center.y * area, area)
            if label == ReconstructedMesh.ceiling { ceilings[key, default: .zero] += weighted }
            else { floors[key, default: .zero] += weighted }
        }
        var heights: [Float] = []
        var elevations: [Float] = []
        var ceilingArea: Float = 0
        var coveredFloorArea: Float = 0
        for (key, sum) in ceilings {
            let elevation = sum.x / sum.y
            let below = floors[key].map { $0.x / $0.y } ?? floorY
            guard let below, plausibleHeights.contains(elevation - below) else { continue }
            heights.append(elevation - below)
            elevations.append(elevation)
            ceilingArea += sum.y
            coveredFloorArea += floors[key]?.y ?? 0
        }
        guard !heights.isEmpty else { return nil }
        let floorArea = floors.values.reduce(Float.zero) { $0 + $1.y }
        return CeilingMeasurement(heightM: median(heights), elevation: median(elevations),
                                  floorCoverage: floorArea > 0 ? min(1, coveredFloorArea / floorArea) : nil,
                                  areaM2: ceilingArea)
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

/// Decides when to ask the volunteer to tilt the phone up. LiDAR reaches a normal ceiling, but
/// a phone held level sees it only at the top edge of the frame, so it can stay missing.
public struct CeilingCaptureHint: Sendable {
    /// How long the area around the volunteer can lack ceiling before asking.
    public var delay: TimeInterval
    /// After looking up without finding a ceiling (too high for LiDAR), stay quiet until this far away.
    public var outOfRangeTravel: Float
    /// Looking up this long without a ceiling means it's out of range here.
    public var lookUpDuration: TimeInterval
    private var lastSatisfied: TimeInterval?
    private var lookingUpSince: TimeInterval?
    private var outOfRangeAt: SIMD2<Float>?

    public init(delay: TimeInterval = 6, outOfRangeTravel: Float = 3, lookUpDuration: TimeInterval = 2) {
        self.delay = delay; self.outOfRangeTravel = outOfRangeTravel; self.lookUpDuration = lookUpDuration
    }

    /// - Returns: Whether to show the hint now.
    public mutating func update(time: TimeInterval, position: SIMD3<Float>, lookingUp: Bool, ceilingNearby: Bool) -> Bool {
        let plan = SIMD2(position.x, position.z)
        if lastSatisfied == nil { lastSatisfied = time }
        if ceilingNearby {
            lastSatisfied = time
            lookingUpSince = nil
            outOfRangeAt = nil
            return false
        }
        if lookingUp {
            let since = lookingUpSince ?? time
            lookingUpSince = since
            if time - since >= lookUpDuration { outOfRangeAt = plan }
        } else {
            lookingUpSince = nil
        }
        if let outOfRangeAt {
            if simd_distance(outOfRangeAt, plan) < outOfRangeTravel { return false }
            self.outOfRangeAt = nil
            lastSatisfied = time
        }
        return time - (lastSatisfied ?? time) >= delay
    }
}
