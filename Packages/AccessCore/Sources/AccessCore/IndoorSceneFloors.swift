import Foundation

public struct IndoorSceneFloor: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Height in the original scan's meter-based world coordinates.
    public var elevation: Float

    public init(id: String, title: String, elevation: Float) {
        self.id = id
        self.title = title
        self.elevation = elevation
    }
}

/// Derives display levels without changing the captured geometry or its AR coordinate frame.
public enum IndoorSceneFloors {
    public static func floors(in scene: ProcessedScene) -> [IndoorSceneFloor] {
        let measured = scene.surfaces.compactMap { surface -> FloorMeasurement? in
            guard surface.kind == "floor", let elevation = floorElevation(surface) else { return nil }
            let dimensions = surface.measuredDimensionsM.sorted(by: >)
            return FloorMeasurement(elevation: elevation, area: Double(dimensions[0]) * Double(dimensions[1]))
        }.sorted { $0.elevation < $1.elevation }

        // Group the small height differences between rooms before deciding which are distinct stories.
        var clusters: [[FloorMeasurement]] = []
        for measurement in measured {
            if let first = clusters.last?.first, measurement.elevation - first.elevation <= roomTolerance {
                clusters[clusters.count - 1].append(measurement)
            } else {
                clusters.append([measurement])
            }
        }
        var levels: [[FloorMeasurement]] = []
        for cluster in clusters {
            if let previous = levels.last,
               representative(cluster) - representative(previous) < minimumLevelSeparation {
                levels[levels.count - 1].append(contentsOf: cluster)
            } else {
                levels.append(cluster)
            }
        }
        return levels.enumerated().map { index, measurements in
            IndoorSceneFloor(
                id: "\(scene.floorID)-level-\(index + 1)",
                title: "Floor \(index + 1)",
                elevation: representative(measurements)
            )
        }
    }

    /// Returns a display-only scene for the selected floor, optionally retaining levels below it.
    /// Original surface footprints, dimensions, and AR transforms are kept exactly as captured.
    public static func scene(
        _ scene: ProcessedScene,
        on floor: IndoorSceneFloor,
        includeLowerFloors: Bool = false
    ) -> ProcessedScene {
        let levels = floors(in: scene)
        var result = scene
        // Unclassified raw detail can cover the cutaway. Continuous scans are different: their
        // fused mesh contains the measured room, while surface records are only sparse anchors.
        result.meshes = []
        result.pointCloud = []
        guard let selectedIndex = levels.firstIndex(where: { $0.id == floor.id }) else {
            result.objects = []
            result.surfaces = []
            return result
        }
        result.floorID = levels[selectedIndex].id

        func isVisible(_ elevation: Float) -> Bool {
            guard elevation.isFinite,
                  elevation >= levels[0].elevation - roomTolerance,
                  elevation < levels[levels.count - 1].elevation + topLevelAllowance else { return false }
            let closest = levels.indices.min {
                abs(levels[$0].elevation - elevation) < abs(levels[$1].elevation - elevation)
            } ?? selectedIndex
            return includeLowerFloors ? closest <= selectedIndex : closest == selectedIndex
        }

        result.surfaces = scene.surfaces.filter { surface in
            if surface.kind == "floor" {
                return floorElevation(surface).map(isVisible) ?? false
            }
            // A cutaway exposes the room; a captured ceiling must not close it again.
            guard surface.kind != "ceiling", let base = baseElevation(surface) else { return false }
            return isVisible(base)
        }
        result.objects = scene.objects.filter { object in
            guard validVector(object.obstacleBounds.min), validVector(object.obstacleBounds.max),
                  zip(object.obstacleBounds.min, object.obstacleBounds.max).allSatisfy({ $0 <= $1 }) else { return false }
            return isVisible(object.obstacleBounds.min[1])
        }
        var roomBases = levels.map(\.elevation)
        for surface in scene.surfaces where surface.kind == "floor" {
            guard let elevation = floorElevation(surface), let index = levels.indices.min(by: {
                abs(levels[$0].elevation - elevation) < abs(levels[$1].elevation - elevation)
            }) else { continue }
            roomBases[index] = min(roomBases[index], elevation)
        }
        let visibleLevels = includeLowerFloors ? Array(0...selectedIndex) : [selectedIndex]
        let bands = visibleLevels.map { index in
            // Use the lowest measured room on each story, rather than the average elevation.
            // The first story also allows imperfect floor anchors from a depth-only scan.
            let lower = roomBases[index] - (index == 0 ? roomTolerance : meshFloorTolerance)
            let nextBase = index + 1 < levels.count ? roomBases[index + 1] : nil
            return MeshDisplayBand(floor: levels[index].elevation, lower: lower,
                                   upper: nextBase.map { $0 - meshFloorTolerance }
                                       ?? levels[index].elevation + topLevelAllowance)
        }
        result.meshes = scene.meshes.compactMap { mesh in
            if mesh.sourceID == "stream-depth-fusion" { return displayMesh(mesh, in: bands) }
            // Classified detail is display evidence only. Renderers omit the single-level ceiling;
            // multiple levels retain just their labeled faces, independently of routing coverage.
            guard let labels = mesh.classifications, labels.count == mesh.triangles.count else { return nil }
            if levels.count == 1 { return mesh }
            let key = MeshCutKey(scanID: scene.sourceScanID, mesh: mesh, elevations: levels.map(\.elevation),
                                 selectedIndex: selectedIndex, includeLowerFloors: includeLowerFloors)
            return meshCuts.value(for: key) {
                cut(mesh, labels: labels, levels: levels, selectedIndex: selectedIndex, includeLowerFloors: includeLowerFloors)
            }
        }
        return result
    }

    /// Clips an already selected floor's measured mesh for a display cutaway.
    /// Stored scan geometry and the original vertices below the cut plane remain unchanged.
    public static func cutawayMesh(_ mesh: SceneMesh, floorY: Float, wallHeight: Float) -> SceneMesh? {
        guard floorY.isFinite, wallHeight.isFinite, wallHeight > 0, (floorY + wallHeight).isFinite else { return nil }
        return displayMesh(mesh, in: [MeshDisplayBand(floor: floorY, lower: -.greatestFiniteMagnitude,
                                                     upper: floorY + wallHeight)])
    }

    private struct MeshDisplayBand {
        var floor: Float
        var lower: Float
        var upper: Float
    }

    private struct MeshVertex {
        var position: [Float]
        var sourceIndex: Int?
        var color: SIMD3<Float>?
    }

    private struct BoundaryVertex: Hashable {
        var position: [Float]
        var color: SIMD3<Float>?
    }

    private static let meshFloorTolerance: Float = 0.025
    private static let overheadHeight: Float = 2

    private static func displayMesh(_ mesh: SceneMesh, in bands: [MeshDisplayBand]) -> SceneMesh? {
        guard mesh.classifications == nil || mesh.classifications?.count == mesh.triangles.count else { return nil }
        var vertices: [[Float]] = []
        var sourceIndices = [Int](repeating: -1, count: mesh.vertices.count)
        var boundaryIndices: [BoundaryVertex: Int] = [:]
        var triangles: [[Int]] = []
        var classifications: [String]? = mesh.classifications.map { _ in [] }
        let sourceColors = mesh.colors.flatMap { $0.count == mesh.vertices.count ? $0 : nil }
        var colors: [UInt32]? = sourceColors.map { _ in [] }
        vertices.reserveCapacity(mesh.vertices.count)
        triangles.reserveCapacity(mesh.triangles.count)
        classifications?.reserveCapacity(mesh.triangles.count)

        func sourceVertexIndex(_ sourceIndex: Int) -> Int {
            if sourceIndices[sourceIndex] >= 0 { return sourceIndices[sourceIndex] }
            let index = vertices.count
            vertices.append(mesh.vertices[sourceIndex])
            if let sourceColors { colors?.append(sourceColors[sourceIndex]) }
            sourceIndices[sourceIndex] = index
            return index
        }

        func vertexIndex(_ vertex: MeshVertex) -> Int {
            if let sourceIndex = vertex.sourceIndex { return sourceVertexIndex(sourceIndex) }
            let key = BoundaryVertex(position: vertex.position, color: vertex.color)
            if let index = boundaryIndices[key] { return index }
            let index = vertices.count
            vertices.append(vertex.position)
            if let color = vertex.color { colors?.append(packedColor(color)) }
            boundaryIndices[key] = index
            return index
        }

        for (faceIndex, face) in mesh.triangles.enumerated() {
            guard face.count == 3, face.allSatisfy({ mesh.vertices.indices.contains($0) }) else { continue }
            let a = mesh.vertices[face[0]], b = mesh.vertices[face[1]], c = mesh.vertices[face[2]]
            guard validVector(a), validVector(b), validVector(c) else { continue }
            let classification = mesh.classifications?[faceIndex]
            guard classification != "ceiling" else { continue }
            let normal = triangleNormal(a, b, c)
            let lengthSquared = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
            guard lengthSquared.isFinite, lengthSquared > 1e-12 else { continue }
            let minimumY = min(a[1], min(b[1], c[1]))
            let maximumY = max(a[1], max(b[1], c[1]))

            for band in bands {
                guard maximumY >= band.lower, minimumY <= band.upper else { continue }
                // Fusion has no per-face semantic labels. Remove horizontal overhead panels
                // for the cutaway, while keeping tall walls and every measured floor triangle.
                if classification == nil,
                   normal.y * normal.y >= lengthSquared * 0.81,
                   minimumY >= band.floor + overheadHeight { continue }
                if minimumY >= band.lower, maximumY <= band.upper {
                    triangles.append(face.map(sourceVertexIndex))
                    if let classification { classifications?.append(classification) }
                    continue
                }
                let original = face.map { index in
                    MeshVertex(position: mesh.vertices[index], sourceIndex: index,
                               color: sourceColors.map { unpackedColor($0[index]) })
                }
                let polygon = clip(clip(original, at: band.lower, keepingAbove: true),
                                   at: band.upper, keepingAbove: false)
                guard polygon.count >= 3 else { continue }
                // Clip crossing triangles to the story boundary instead of dropping whole
                // faces, which would leave holes in otherwise continuous measured walls.
                for index in 1..<(polygon.count - 1) {
                    let a = polygon[0], b = polygon[index], c = polygon[index + 1]
                    let clippedNormal = triangleNormal(a.position, b.position, c.position)
                    guard clippedNormal.x * clippedNormal.x + clippedNormal.y * clippedNormal.y
                            + clippedNormal.z * clippedNormal.z > 1e-12 else { continue }
                    triangles.append([vertexIndex(a), vertexIndex(b), vertexIndex(c)])
                    if let classification { classifications?.append(classification) }
                }
            }
        }
        guard !triangles.isEmpty else { return nil }
        return SceneMesh(sourceID: mesh.sourceID, vertices: vertices, triangles: triangles,
                         classifications: classifications, colors: colors)
    }

    private static func triangleNormal(_ a: [Float], _ b: [Float], _ c: [Float]) -> SIMD3<Float> {
        let u = SIMD3(b[0] - a[0], b[1] - a[1], b[2] - a[2])
        let v = SIMD3(c[0] - a[0], c[1] - a[1], c[2] - a[2])
        return SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    }

    private static func clip(_ polygon: [MeshVertex], at height: Float, keepingAbove: Bool) -> [MeshVertex] {
        guard let last = polygon.last else { return [] }
        func inside(_ vertex: MeshVertex) -> Bool {
            keepingAbove ? vertex.position[1] >= height : vertex.position[1] <= height
        }
        var result: [MeshVertex] = []
        var previous = last
        var previousInside = inside(previous)
        for current in polygon {
            let currentInside = inside(current)
            if currentInside != previousInside {
                let a = previous.position, b = current.position
                let t = (height - a[1]) / (b[1] - a[1])
                var intersection = (0..<3).map { a[$0] + t * (b[$0] - a[$0]) }
                intersection[1] = height
                let color: SIMD3<Float>?
                if let a = previous.color, let b = current.color { color = a + t * (b - a) }
                else { color = nil }
                result.append(MeshVertex(position: intersection, sourceIndex: nil, color: color))
            }
            if currentInside { result.append(current) }
            previous = current
            previousInside = currentInside
        }
        return result
    }

    private static func unpackedColor(_ color: UInt32) -> SIMD3<Float> {
        SIMD3(Float(color >> 16 & 0xFF), Float(color >> 8 & 0xFF), Float(color & 0xFF))
    }

    private static func packedColor(_ color: SIMD3<Float>) -> UInt32 {
        UInt32(min(255, max(0, color.x.rounded()))) << 16
            | UInt32(min(255, max(0, color.y.rounded()))) << 8
            | UInt32(min(255, max(0, color.z.rounded())))
    }

    /// The faces of a labeled mesh on the selected level, without its ceiling. A face belongs to
    /// the highest level at or just below its lowest corner, so the tops of a room's walls stay
    /// with the room rather than the floor above.
    private static func cut(_ mesh: SceneMesh, labels: [String], levels: [IndoorSceneFloor],
                            selectedIndex: Int, includeLowerFloors: Bool) -> SceneMesh? {
        guard let first = levels.first, let last = levels.last else { return nil }
        var remap = [Int](repeating: -1, count: mesh.vertices.count)
        var vertices: [[Float]] = []
        var colors: [UInt32] = []
        let sourceColors = mesh.colors.flatMap { $0.count == mesh.vertices.count ? $0 : nil }
        var triangles: [[Int]] = []
        var classifications: [String] = []
        for (index, triangle) in mesh.triangles.enumerated() where labels[index] != ReconstructedMesh.ceiling {
            guard triangle.count == 3, triangle.allSatisfy({ mesh.vertices.indices.contains($0) && mesh.vertices[$0].count == 3 }),
                  let base = triangle.map({ mesh.vertices[$0][1] }).min(), base.isFinite,
                  base >= first.elevation - roomTolerance, base < last.elevation + topLevelAllowance else { continue }
            let level = levels.lastIndex { $0.elevation <= base + meshLevelTolerance } ?? 0
            guard includeLowerFloors ? level <= selectedIndex : level == selectedIndex else { continue }
            triangles.append(triangle.map { vertex in
                if remap[vertex] < 0 {
                    remap[vertex] = vertices.count
                    vertices.append(mesh.vertices[vertex])
                    if let sourceColors { colors.append(sourceColors[vertex]) }
                }
                return remap[vertex]
            })
            classifications.append(labels[index])
        }
        guard !triangles.isEmpty else { return nil }
        return SceneMesh(sourceID: mesh.sourceID, vertices: vertices, triangles: triangles, classifications: classifications,
                         colors: sourceColors == nil ? nil : colors)
    }

    /// SwiftUI rebuilds floor content on every update; a cut is made once per floor choice.
    private static let meshCuts = MeshCutCache()

    /// Content, including vertex colors, identifies a revision. Counts alone reuse stale cuts
    /// after recoloring or a corrected reconstruction with the same number of faces.
    private struct MeshCutKey: Hashable {
        var scanID: String
        var mesh: SceneMesh
        var elevations: [Float]
        var selectedIndex: Int
        var includeLowerFloors: Bool
    }

    private final class MeshCutCache: @unchecked Sendable {
        private struct Entry { var mesh: SceneMesh? }
        private let lock = NSLock()
        private var entries: [MeshCutKey: Entry] = [:]

        func value(for key: MeshCutKey, make: () -> SceneMesh?) -> SceneMesh? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = entries[key] { return cached.mesh }
            // A handful of floors per open map; dropping everything bounds memory across maps.
            if entries.count >= 4 { entries.removeAll() }
            let value = make()
            entries[key] = Entry(mesh: value)
            return value
        }
    }

    private struct FloorMeasurement {
        var elevation: Float
        var area: Double
    }

    /// Floors in one reconstructed mesh sit within a few centimeters of their level.
    private static let meshLevelTolerance: Float = 0.15
    private static let roomTolerance: Float = 0.5
    private static let minimumLevelSeparation: Float = 2
    // There is no next measured floor above the top level. This bounds stray geometry while
    // retaining furniture and wall-mounted items within a normal room height.
    private static let topLevelAllowance: Float = 3

    private static func representative(_ measurements: [FloorMeasurement]) -> Float {
        // Weight measured room floors more heavily than a small landing or step.
        let totalArea = measurements.reduce(0.0) { $0 + $1.area }
        let weightedHeight = measurements.reduce(0.0) { $0 + Double($1.elevation) * $1.area }
        return Float(weightedHeight / totalArea)
    }

    private static func validSurface(_ surface: SceneSurface) -> Bool {
        validRigidTransform(surface.mapFromSurface)
            && validVector(surface.measuredDimensionsM)
            && surface.measuredDimensionsM.allSatisfy { $0 >= 0 }
            && surface.measuredDimensionsM.filter { $0 > 0 }.count >= 2
    }

    private static func floorElevation(_ surface: SceneSurface) -> Float? {
        guard validSurface(surface),
              let normalAxis = surface.measuredDimensionsM.indices.min(by: {
                  surface.measuredDimensionsM[$0] < surface.measuredDimensionsM[$1]
              }),
              abs(surface.mapFromSurface[normalAxis * 4 + 1]) >= 0.9 else { return nil }
        return surface.mapFromSurface[13]
    }

    private static func baseElevation(_ surface: SceneSurface) -> Float? {
        guard validSurface(surface) else { return nil }
        // Transform the box's extent into world Y; local Y is not always vertical in RoomPlan.
        let verticalExtent = (0..<3).reduce(0.0) {
            $0 + abs(Double(surface.mapFromSurface[$1 * 4 + 1])) * Double(surface.measuredDimensionsM[$1])
        }
        let base = Float(Double(surface.mapFromSurface[13]) - verticalExtent / 2)
        return base.isFinite ? base : nil
    }
}
