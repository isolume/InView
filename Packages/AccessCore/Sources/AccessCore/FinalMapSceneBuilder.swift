import Foundation
import simd

/// Creates a calm, structural presentation of a scan without changing its capture or routing map.
/// Recovered surfaces are display-only: they never establish navigable floor coverage.
public enum FinalMapSceneBuilder {
    /// Validates the complete input before any story selection can hide invalid or excessive geometry.
    public static func validateInput(
        _ scene: ProcessedScene,
        floorFootprints: [Footprint] = [],
        floorY: Float? = nil
    ) throws {
        try Task.checkCancellation()
        guard floorY == nil || floorY!.isFinite,
              scene.meshes.reduce(0, { $0 + $1.triangles.count }) <= Limits.triangles,
              scene.meshes.reduce(0, { $0 + $1.vertices.count }) <= Limits.vertices,
              scene.surfaces.count <= Limits.records, scene.objects.count <= Limits.records,
              floorFootprints.count <= Limits.records else {
            throw SceneValidationError.invalid("The scan is too large to prepare a map preview.")
        }
        try scene.validate()
        _ = try authoritativeFloors(floorFootprints, selected: nil)
        try Task.checkCancellation()
    }

    public static func make(
        from scene: ProcessedScene,
        floorFootprints: [Footprint] = [],
        floorY: Float? = nil
    ) throws -> ProcessedScene {
        try validateInput(scene, floorFootprints: floorFootprints, floorY: floorY)
        var result = scene
        result.meshes = []
        result.pointCloud = []
        let inputFloors = try authoritativeFloors(floorFootprints, selected: floorY)
        var surfaces = scene.surfaces.filter { surface in
            guard surface.kind != "ceiling" else { return false }
            guard let floorY else { return true }
            let bounds = worldBounds(surface)
            if surface.kind == "floor" { return abs(surface.mapFromSurface[13] - floorY) < 0.4 }
            return bounds.max.y >= Double(floorY) - 0.25 && bounds.min.y < Double(floorY) + 2.8
        }
        surfaces = replaceFloors(in: surfaces, with: inputFloors)
        surfaces = coalesceWalls(surfaces)
        for index in surfaces.indices {
            surfaces[index].color = color(for: surfaces[index].kind)
        }
        result.objects = scene.objects.filter { object in
            guard let floorY else { return true }
            return object.obstacleBounds.max[1] >= floorY - 0.25
                && object.obstacleBounds.min[1] < floorY + 2.2
        }.map { object in
            var display = object
            if ["bounds_v1", "bounds", "unknown"].contains(object.modelKey) {
                display.parts = [SceneModelPart(center: [0, 0, 0],
                    dimensionsM: object.measuredDimensionsM, color: "#C6CBC7")]
                display.modelMeshes = []
            } else {
                for index in display.parts.indices { display.parts[index].color = "#CBD1CC" }
                for index in display.modelMeshes.indices { display.modelMeshes[index].color = "#CBD1CC" }
            }
            return display
        }
        let faces = try measuredFaces(scene.meshes)
        let floors = surfaces.filter { $0.kind == "floor" }.map(floorRegion)
        let levels = floorY.map { [$0] } ?? floorLevels(floors, faces: faces)
        var usedIDs = Set(surfaces.map(\.sourceID))
        var budget = WorkBudget()
        for (levelIndex, elevation) in levels.enumerated() {
            try Task.checkCancellation()
            let knownFloors = floors.filter { abs($0.elevation - elevation) < 0.4 }
            let recovered = try recoverFloors(faces, elevation: elevation, known: knownFloors,
                                              objects: result.objects, budget: &budget)
            for (index, rectangle) in recovered.enumerated() {
                let id = uniqueID("final-map-floor-\(levelIndex)-\(index)", used: &usedIDs)
                surfaces.append(horizontalSurface(id, rectangle: rectangle, elevation: elevation))
            }
            let support = knownFloors + recovered.map { FloorRegion(points: $0.corners, elevation: elevation) }
            let next = levels.filter { $0 > elevation + 0.7 }.min()
            let upper = min(elevation + 3.2, next.map { $0 - 0.12 } ?? elevation + 3.2)
            let walls = try recoverWalls(faces, elevation: elevation, upper: upper,
                                        floors: support, surfaces: surfaces, objects: result.objects,
                                        budget: &budget)
            for (index, wall) in walls.enumerated() {
                let id = uniqueID("final-map-wall-\(levelIndex)-\(index)", used: &usedIDs)
                surfaces.append(verticalSurface(id, wall: wall))
            }
        }
        result.surfaces = surfaces
        try Task.checkCancellation()
        try result.validate()
        return result
    }

    private enum Limits {
        static let triangles = 200_000
        static let vertices = 400_000
        static let records = 4_000
        static let cells = 60_000
        static let cellVisits = 1_200_000
        static let work = 24_000_000
        static let polygonsPerCell = 96
        static let uncoveredPieces = 96
        static let panels = 768
        static let planeGroups = 192
    }

    private struct WorkBudget {
        var spent = 0
        var visits = 0
        mutating func spend(_ amount: Int) -> Bool {
            guard amount <= Limits.work - spent else { return false }
            spent += amount
            return true
        }
        mutating func visit() -> Bool {
            guard visits < Limits.cellVisits else { return false }
            visits += 1
            return true
        }
    }

    private typealias Point = SIMD2<Double>
    private struct Rectangle {
        var min: Point
        var max: Point
        var area: Double { (max.x - min.x) * (max.y - min.y) }
        var corners: [Point] { [min, Point(max.x, min.y), max, Point(min.x, max.y)] }
    }
    private struct FloorRegion {
        var points: [Point]
        var elevation: Float
        var bounds: Rectangle { rectangle(points) }
    }
    private struct Face {
        var points: [SIMD3<Double>]
        var normal: SIMD3<Double>
        var area: Double
        var classification: String?
        var center: SIMD3<Double> { (points[0] + points[1] + points[2]) / 3 }
        var minY: Double { points.map(\.y).min()! }
        var maxY: Double { points.map(\.y).max()! }
    }
    private struct Cell: Hashable, Comparable {
        var x: Int
        var y: Int
        static func < (a: Cell, b: Cell) -> Bool { a.y == b.y ? a.x < b.x : a.y < b.y }
    }
    private struct PlaneKey: Hashable, Comparable {
        var angle: Int
        var offset: Int
        static func < (a: PlaneKey, b: PlaneKey) -> Bool {
            a.angle == b.angle ? a.offset < b.offset : a.angle < b.angle
        }
    }
    private struct Wall {
        var rectangle: Rectangle
        var tangent: Point
        var normal: Point
        var offset: Double
    }

    private static func color(for kind: String) -> String {
        switch kind {
        case "floor": return "#EEF0EB"
        case "wall": return "#F1F3EE"
        case "window": return "#C4CCCA"
        default: return "#D4DBD5"
        }
    }

    private static func authoritativeFloors(_ footprints: [Footprint], selected: Float?) throws -> [FloorRegion] {
        try footprints.filter { $0.kind == .floor }.compactMap { footprint in
            try Task.checkCancellation()
            let elevation = footprint.bottom ?? selected ?? 0
            guard elevation.isFinite, footprint.center.x.isFinite, footprint.center.y.isFinite,
                  footprint.yaw.isFinite, footprint.size.x.isFinite, footprint.size.y.isFinite,
                  footprint.corners.count <= 128,
                  footprint.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw SceneValidationError.invalid("The map contains an invalid floor outline.")
            }
            if let selected, abs(elevation - selected) >= 0.4 { return nil }
            let points = footprint.corners.map { Point(Double($0.x), Double($0.y)) }
            guard points.count >= 3, abs(signedArea(points)) > 0.0001 else { return nil }
            return FloorRegion(points: points, elevation: elevation)
        }
    }

    /// Map footprints carry exact coverage, while some continuous-scan floor anchors only carry a box.
    private static func replaceFloors(in surfaces: [SceneSurface], with floors: [FloorRegion]) -> [SceneSurface] {
        guard !floors.isEmpty else { return surfaces }
        var result = surfaces.filter { surface in
            surface.kind != "floor" || !floors.contains { abs($0.elevation - surface.mapFromSurface[13]) < 0.4 }
        }
        var available = surfaces.filter { $0.kind == "floor" }
        var used = Set(result.map(\.sourceID))
        for (index, floor) in floors.enumerated() {
            let center = (floor.bounds.min + floor.bounds.max) / 2
            let match = available.indices.filter { abs(available[$0].mapFromSurface[13] - floor.elevation) < 0.4 }
                .min { a, b in
                    let ca = floorRegion(available[a]).bounds, cb = floorRegion(available[b]).bounds
                    return simd_length_squared((ca.min + ca.max) / 2 - center)
                        < simd_length_squared((cb.min + cb.max) / 2 - center)
                }
            let id: String
            if let match { id = available.remove(at: match).sourceID; used.insert(id) }
            else { id = uniqueID("final-map-measured-floor-\(index)", used: &used) }
            result.append(horizontalSurface(id, region: floor))
        }
        return result
    }

    private static func floorRegion(_ surface: SceneSurface) -> FloorRegion {
        let dimensions = surface.measuredDimensionsM
        let local: [[Float]]
        if let polygon = surface.polygonCorners { local = polygon }
        else {
            let normal = dimensions.indices.min { dimensions[$0] < dimensions[$1] } ?? 1
            let axes = dimensions.indices.filter { $0 != normal }
            local = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map { signs in
                var point = [Float](repeating: 0, count: 3)
                point[axes[0]] = Float(signs[0]) * dimensions[axes[0]] / 2
                point[axes[1]] = Float(signs[1]) * dimensions[axes[1]] / 2
                return point
            }
        }
        return FloorRegion(points: local.map { point in
            let world = mapPoint(point, surface.mapFromSurface)
            return Point(world.x, world.z)
        }, elevation: surface.mapFromSurface[13])
    }

    private static func measuredFaces(_ meshes: [SceneMesh]) throws -> [Face] {
        var result: [Face] = []
        for mesh in meshes where mesh.sourceID == "stream-depth-fusion" {
            for (index, triangle) in mesh.triangles.enumerated() {
                if index % 512 == 0 { try Task.checkCancellation() }
                let points = triangle.map { index in SIMD3<Double>(mesh.vertices[index].map(Double.init)) }
                // A single stray long face must not establish a floor across unobserved space.
                guard points.allSatisfy({ abs($0.x) <= 250 && abs($0.z) <= 250 && abs($0.y) <= 100 }),
                      (0..<3).allSatisfy({ simd_length_squared(points[$0] - points[($0 + 1) % 3]) <= 400 }) else { continue }
                let cross = simd_cross(points[1] - points[0], points[2] - points[0])
                let length = simd_length(cross)
                guard length > 0.000001 else { continue }
                let classification = mesh.classifications?[index]
                guard classification == nil || ["floor", "wall", "none", "unknown"].contains(classification!) else { continue }
                result.append(Face(points: points, normal: cross / length, area: length / 2,
                                   classification: classification))
            }
        }
        return result
    }

    private static func floorLevels(_ floors: [FloorRegion], faces: [Face]) -> [Float] {
        var levels: [Float] = []
        for floor in floors.sorted(by: { $0.elevation < $1.elevation }) {
            if !levels.contains(where: { abs($0 - floor.elevation) < 0.4 }) { levels.append(floor.elevation) }
        }
        if !levels.isEmpty { return Array(levels.prefix(12)) }
        var histogram: [Int: Double] = [:]
        for face in faces where abs(face.normal.y) >= 0.96 && face.maxY - face.minY < 0.18 {
            histogram[Int((face.center.y / 0.08).rounded()), default: 0] += face.area
        }
        // Isolated low triangles are not a story. Prefer the lowest substantial plane,
        // rather than a table or the better-observed ceiling above it.
        let clusters = histogram.keys.sorted().map { key in
            (height: Double(key) * 0.08, area: (key - 1...key + 1).reduce(0.0) { $0 + (histogram[$1] ?? 0) })
        }
        let largest = clusters.map(\.area).max() ?? 0
        guard largest >= 0.6,
              let floor = clusters.first(where: { $0.area >= max(0.6, largest * 0.2) }) else { return [] }
        return [Float(floor.height)]
    }

    private static func recoverFloors(
        _ faces: [Face], elevation: Float, known: [FloorRegion], objects: [SceneObject], budget: inout WorkBudget
    ) throws -> [Rectangle] {
        let polygons = faces.compactMap { face -> [Point]? in
            guard abs(face.normal.y) >= 0.96, face.maxY - face.minY <= 0.18,
                  abs(face.center.y - Double(elevation)) <= 0.15,
                  face.minY >= Double(elevation) - 0.22,
                  face.maxY <= Double(elevation) + 0.22,
                  face.classification != "wall" else { return nil }
            // A known object can be short enough to lie inside the floor-height tolerance.
            if objects.contains(where: { contains(face.center, object: $0, inset: 0.015)
                && face.center.y > Double($0.obstacleBounds.min[1]) + 0.05 }) { return nil }
            return counterclockwise(face.points.map { Point($0.x, $0.z) })
        }
        let step = Point(0.15, 0.15)
        var cells = try supportedCells(polygons, step: step, budget: &budget)
        cells = try significantComponents(cells, step: step, anchors: known)
        // Authoritative floor outlines may include concave gaps; never use their bounds as coverage.
        if !known.isEmpty {
            cells = Set(cells.filter { cell in
                let cellRectangle = cellBounds(cell, step: step)
                return !known.contains { region in
                    overlaps(cellRectangle, region.bounds) && polygonsOverlap(cellRectangle.corners, region.points)
                }
            })
        }
        return mergedRectangles(cells, step: step, limit: Limits.panels)
    }

    private static func recoverWalls(
        _ faces: [Face], elevation: Float, upper: Float, floors: [FloorRegion], surfaces: [SceneSurface],
        objects: [SceneObject], budget: inout WorkBudget
    ) throws -> [Wall] {
        guard !floors.isEmpty else { return [] }
        let angleStep = Double.pi / 36
        var groups: [PlaneKey: [Int]] = [:]
        for (index, face) in faces.enumerated() {
            if index % 512 == 0 { try Task.checkCancellation() }
            guard abs(face.normal.y) <= 0.16,
                  face.maxY >= Double(elevation) - 0.15, face.minY < Double(upper),
                  face.classification != "floor",
                  !objects.contains(where: { contains(face.center, object: $0, inset: -0.025) }) else { continue }
            var angle = atan2(face.normal.z, face.normal.x)
            if angle < 0 { angle += Double.pi }
            if angle >= Double.pi { angle -= Double.pi }
            let bin = Int((angle / angleStep).rounded()) % 36
            let normal = Point(cos(Double(bin) * angleStep), sin(Double(bin) * angleStep))
            let offset = simd_dot(normal, Point(face.center.x, face.center.z))
            groups[PlaneKey(angle: bin, offset: Int((offset / 0.12).rounded())), default: []].append(index)
        }
        // Process substantial planes first; a bounded number of hypotheses prevents clutter
        // from turning a large scan into thousands of expensive geometry operations.
        let keys = groups.keys.sorted { a, b in
            let areaA = groups[a]!.reduce(0.0) { $0 + faces[$1].area }
            let areaB = groups[b]!.reduce(0.0) { $0 + faces[$1].area }
            return abs(areaA - areaB) > 0.000001 ? areaA > areaB : a < b
        }
        var consumed: Set<PlaneKey> = []
        var result: [Wall] = []
        for key in keys.prefix(Limits.planeGroups) where !consumed.contains(key) {
            try Task.checkCancellation()
            let angle = Double(key.angle) * angleStep
            let seedNormal = Point(cos(angle), sin(angle))
            let seedOffset = Double(key.offset) * 0.12
            let neighborKeys = keys.filter { candidate in
                guard !consumed.contains(candidate) else { return false }
                let theta = Double(candidate.angle) * angleStep
                let normal = Point(cos(theta), sin(theta))
                let sign = simd_dot(seedNormal, normal) >= 0 ? 1.0 : -1.0
                return abs(simd_dot(seedNormal, normal)) >= cos(angleStep * 1.1)
                    && abs(Double(candidate.offset) * 0.12 * sign - seedOffset) <= 0.19
            }
            let indices = neighborKeys.flatMap { groups[$0]! }
            let area = indices.reduce(0.0) { $0 + faces[$1].area }
            guard area >= 0.75 else { continue }
            var normal = indices.reduce(Point.zero) { sum, index in
                let n = Point(faces[index].normal.x, faces[index].normal.z)
                return sum + n * (simd_dot(n, seedNormal) >= 0 ? faces[index].area : -faces[index].area)
            }
            guard simd_length(normal) > 0.0001 else { continue }
            normal = simd_normalize(normal)
            let offset = indices.reduce(0.0) {
                $0 + simd_dot(normal, Point(faces[$1].center.x, faces[$1].center.z)) * faces[$1].area
            } / area
            let tangent = Point(normal.y, -normal.x)
            let accepted = indices.filter { index in
                let face = faces[index]
                return abs(simd_dot(Point(face.normal.x, face.normal.z), normal)) >= 0.98
                    && face.points.allSatisfy { abs(simd_dot(normal, Point($0.x, $0.z)) - offset) <= 0.12 }
            }
            let polygons = accepted.compactMap { index -> [Point]? in
                let face = faces[index]
                let projected = counterclockwise(face.points.map { Point(simd_dot(tangent, Point($0.x, $0.z)), $0.y) })
                let band = Rectangle(min: Point(-500, Double(elevation)), max: Point(500, Double(upper)))
                let clipped = intersect(projected, with: band.corners)
                return clipped.count >= 3 ? clipped : nil
            }
            guard !polygons.isEmpty else { continue }
            let bounds = rectangle(polygons.flatMap { $0 })
            guard bounds.max.y - bounds.min.y >= 1.3, bounds.max.x - bounds.min.x >= 0.6,
                  bounds.min.y <= Double(elevation) + 0.3,
                  area / max(bounds.area, 0.01) >= 0.22 else { continue }
            let basePoints = [bounds.min.x, (bounds.min.x + bounds.max.x) / 2, bounds.max.x].map {
                tangent * $0 + normal * offset
            }
            guard basePoints.contains(where: { point in floors.contains { near(point, polygon: $0.points, distance: 0.4) } }) else { continue }
            neighborKeys.forEach { consumed.insert($0) }
            let step = Point(0.15, 0.2)
            var cells = try supportedCells(polygons, step: step, budget: &budget)
            let exclusions = surfaces.compactMap { surface -> Rectangle? in
                guard ["wall", "door", "opening", "window"].contains(surface.kind) else { return nil }
                let corners = worldCorners(surface)
                guard corners.allSatisfy({ abs(simd_dot(normal, Point($0.x, $0.z)) - offset) <= 0.22 }) else { return nil }
                return rectangle(corners.map { Point(simd_dot(tangent, Point($0.x, $0.z)), $0.y) })
            }
            // Reserve measured openings even where fusion contains a spurious face across them.
            cells = Set(cells.filter { cell in
                let panel = cellBounds(cell, step: step)
                return !exclusions.contains(where: { overlaps(panel, $0) })
            })
            cells = try supportedWallComponents(cells, step: step, elevation: elevation)
            let panels = mergedRectangles(cells, step: step, limit: Limits.panels - result.count)
            for panel in panels {
                result.append(Wall(rectangle: panel, tangent: tangent, normal: normal, offset: offset))
            }
            if result.count >= Limits.panels { break }
        }
        return result
    }

    /// Exact convex subtraction verifies that the whole cell is observed. Center samples alone
    /// would bridge holes or turn a triangle's bounding box into invented floor coverage.
    private static func supportedCells(
        _ polygons: [[Point]], step: Point, budget: inout WorkBudget
    ) throws -> Set<Cell> {
        var candidates: [Cell: [[Point]]] = [:]
        for (index, polygon) in polygons.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            if budget.visits >= Limits.cellVisits { break }
            let bounds = rectangle(polygon)
            let lower = Cell(x: Int(floor(bounds.min.x / step.x)), y: Int(floor(bounds.min.y / step.y)))
            let upper = Cell(x: Int(ceil(bounds.max.x / step.x)) - 1, y: Int(ceil(bounds.max.y / step.y)) - 1)
            guard upper.x >= lower.x, upper.y >= lower.y,
                  (upper.x - lower.x + 1) * (upper.y - lower.y + 1) <= Limits.cells else { continue }
            for y in lower.y...upper.y {
                for x in lower.x...upper.x {
                    guard budget.visit() else { break }
                    let cell = Cell(x: x, y: y)
                    if candidates[cell] == nil && candidates.count >= Limits.cells { continue }
                    if (candidates[cell]?.count ?? 0) >= Limits.polygonsPerCell { continue }
                    let clipped = intersect(polygon, with: cellBounds(cell, step: step).corners)
                    if clipped.count >= 3, abs(signedArea(clipped)) > 0.00000001 {
                        candidates[cell, default: []].append(clipped)
                    }
                }
            }
        }
        var supported: Set<Cell> = []
        for (index, cell) in candidates.keys.sorted().enumerated() {
            if index % 128 == 0 { try Task.checkCancellation() }
            var uncovered = [cellBounds(cell, step: step).corners]
            var complete = true
            for mask in candidates[cell]! {
                var remainder: [[Point]] = []
                for piece in uncovered {
                    guard budget.spend(piece.count * mask.count), remainder.count < Limits.uncoveredPieces else {
                        complete = false
                        break
                    }
                    remainder.append(contentsOf: subtract(mask, from: piece))
                }
                if !complete { break }
                uncovered = remainder
                if uncovered.isEmpty { break }
            }
            // Float-generated triangle edges differ by a few micrometers. The tolerance is
            // an area roundoff allowance, not a dilation or gap-closing operation.
            if complete && uncovered.reduce(0.0, { $0 + abs(signedArea($1)) }) <= 0.0000002 {
                supported.insert(cell)
            }
        }
        return supported
    }

    private static func significantComponents(
        _ cells: Set<Cell>, step: Point, anchors: [FloorRegion]
    ) throws -> Set<Cell> {
        let components = try connectedComponents(cells, step: step)
        guard let largest = components.max(by: { $0.cells.count < $1.cells.count }) else { return [] }
        let minimum = max(0.45, Double(largest.cells.count) * step.x * step.y * 0.012)
        return Set(components.filter { component in
            let area = Double(component.cells.count) * step.x * step.y
            guard area >= minimum else { return false }
            let close = rectangleDistance(component.bounds, largest.bounds) <= 5
                || anchors.contains { rectangleDistance(component.bounds, $0.bounds) <= 1 }
            return close || component.cells.count >= largest.cells.count / 5
        }.flatMap(\.cells))
    }

    /// Unrelated fragments can collectively have the height and area of a wall plane. Each
    /// connected observation must instead establish its own upright, floor-supported panel.
    /// No cells are added, and openings remain gaps between the retained observations.
    private static func supportedWallComponents(
        _ cells: Set<Cell>, step: Point, elevation: Float
    ) throws -> Set<Cell> {
        let components = try connectedComponents(cells, step: step)
        return Set(components.filter { component in
            let extent = component.bounds.max - component.bounds.min
            let area = Double(component.cells.count) * step.x * step.y
            return component.bounds.min.y <= Double(elevation) + 0.25
                && extent.y >= 1.3 && extent.x >= 0.45 - 1e-9 && area >= 0.75
        }.flatMap(\.cells))
    }

    private static func connectedComponents(
        _ cells: Set<Cell>, step: Point
    ) throws -> [(cells: [Cell], bounds: Rectangle)] {
        var remaining = cells
        var components: [(cells: [Cell], bounds: Rectangle)] = []
        for seed in cells.sorted() where remaining.contains(seed) {
            try Task.checkCancellation()
            var queue = [seed]
            remaining.remove(seed)
            var index = 0
            while index < queue.count {
                let cell = queue[index]
                index += 1
                for next in [Cell(x: cell.x - 1, y: cell.y), Cell(x: cell.x + 1, y: cell.y),
                             Cell(x: cell.x, y: cell.y - 1), Cell(x: cell.x, y: cell.y + 1)] {
                    if remaining.remove(next) != nil { queue.append(next) }
                }
            }
            let lowerX = queue.map(\.x).min()!, upperX = queue.map(\.x).max()!
            let lowerY = queue.map(\.y).min()!, upperY = queue.map(\.y).max()!
            components.append((queue, Rectangle(min: Point(Double(lowerX) * step.x, Double(lowerY) * step.y),
                                               max: Point(Double(upperX + 1) * step.x, Double(upperY + 1) * step.y))))
        }
        return components
    }

    private static func mergedRectangles(_ cells: Set<Cell>, step: Point, limit: Int) -> [Rectangle] {
        guard limit > 0 else { return [] }
        var rows: [Int: [Int]] = [:]
        for cell in cells { rows[cell.y, default: []].append(cell.x) }
        struct Run: Hashable { var start: Int; var end: Int }
        var active: [Run: (startY: Int, endY: Int)] = [:]
        var result: [Rectangle] = []
        func emit(_ run: Run, _ band: (startY: Int, endY: Int)) {
            result.append(Rectangle(min: Point(Double(run.start) * step.x, Double(band.startY) * step.y),
                                    max: Point(Double(run.end + 1) * step.x, Double(band.endY + 1) * step.y)))
        }
        var previousY: Int?
        for y in rows.keys.sorted() {
            if previousY.map({ y != $0 + 1 }) ?? false {
                for (run, band) in active { emit(run, band) }
                active = [:]
            }
            let xs = rows[y]!.sorted()
            var runs: [Run] = []
            for x in xs {
                if let last = runs.last, x == last.end + 1 { runs[runs.count - 1].end = x }
                else { runs.append(Run(start: x, end: x)) }
            }
            let current = Set(runs)
            for run in Array(active.keys) where !current.contains(run) { emit(run, active.removeValue(forKey: run)!) }
            for run in runs {
                if let band = active[run] { active[run] = (band.startY, y) }
                else { active[run] = (y, y) }
            }
            previousY = y
        }
        for (run, band) in active { emit(run, band) }
        // Under pathological fragmentation, omit the smallest panels instead of filling unknown gaps.
        return Array(result.sorted {
            if abs($0.area - $1.area) > 0.0000001 { return $0.area > $1.area }
            if $0.min.y != $1.min.y { return $0.min.y < $1.min.y }
            return $0.min.x < $1.min.x
        }.prefix(limit)).sorted {
            $0.min.y == $1.min.y ? $0.min.x < $1.min.x : $0.min.y < $1.min.y
        }
    }

    private static func horizontalSurface(_ id: String, rectangle: Rectangle, elevation: Float) -> SceneSurface {
        horizontalSurface(id, region: FloorRegion(points: rectangle.corners, elevation: elevation))
    }

    private static func horizontalSurface(_ id: String, region: FloorRegion) -> SceneSurface {
        let bounds = region.bounds, center = (bounds.min + bounds.max) / 2, size = bounds.max - bounds.min
        return SceneSurface(sourceID: id, kind: "floor",
            mapFromSurface: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, Float(center.x), region.elevation, Float(center.y), 1],
            measuredDimensionsM: [Float(size.x), 0, Float(size.y)],
            renderDimensionsM: [Float(size.x), 0.12, Float(size.y)], color: color(for: "floor"),
            polygonCorners: region.points.map { [Float($0.x - center.x), 0, Float($0.y - center.y)] })
    }

    private static func verticalSurface(_ id: String, wall: Wall) -> SceneSurface {
        let center = (wall.rectangle.min + wall.rectangle.max) / 2
        let size = wall.rectangle.max - wall.rectangle.min
        let position = wall.tangent * center.x + wall.normal * wall.offset
        return SceneSurface(sourceID: id, kind: "wall",
            mapFromSurface: [Float(wall.tangent.x), 0, Float(wall.tangent.y), 0, 0, 1, 0, 0,
                Float(wall.normal.x), 0, Float(wall.normal.y), 0, Float(position.x), Float(center.y), Float(position.y), 1],
            measuredDimensionsM: [Float(size.x), Float(size.y), 0],
            renderDimensionsM: [Float(size.x), Float(size.y), 0.10], color: color(for: "wall"))
    }

    private static func coalesceWalls(_ surfaces: [SceneSurface]) -> [SceneSurface] {
        var result: [SceneSurface] = []
        for surface in surfaces {
            guard surface.kind == "wall", let wall = uprightWall(surface) else { result.append(surface); continue }
            let index = result.indices.first { index in
                guard result[index].kind == "wall", let other = uprightWall(result[index]),
                      abs(simd_dot(wall.normal, other.normal)) > 0.9995,
                      abs(simd_dot(wall.normal, other.tangent * other.rectangle.min.x + other.normal * other.offset) - wall.offset) < 0.025,
                      abs(wall.rectangle.min.y - other.rectangle.min.y) < 0.025,
                      abs(wall.rectangle.max.y - other.rectangle.max.y) < 0.025 else { return false }
                let sign = simd_dot(wall.tangent, other.tangent) >= 0 ? 1.0 : -1.0
                let lower = min(other.rectangle.min.x * sign, other.rectangle.max.x * sign)
                let upper = max(other.rectangle.min.x * sign, other.rectangle.max.x * sign)
                let overlap = min(wall.rectangle.max.x, upper) - max(wall.rectangle.min.x, lower)
                return overlap > min(wall.rectangle.max.x - wall.rectangle.min.x, upper - lower) * 0.55
            }
            if let index, let previous = uprightWall(result[index]) {
                let sign = simd_dot(previous.tangent, wall.tangent) >= 0 ? 1.0 : -1.0
                var merged = previous
                merged.rectangle.min.x = min(previous.rectangle.min.x, min(wall.rectangle.min.x * sign, wall.rectangle.max.x * sign))
                merged.rectangle.max.x = max(previous.rectangle.max.x, max(wall.rectangle.min.x * sign, wall.rectangle.max.x * sign))
                if abs(merged.rectangle.min.x - previous.rectangle.min.x) < 0.000001,
                   abs(merged.rectangle.max.x - previous.rectangle.max.x) < 0.000001 { continue }
                result[index] = verticalSurface(result[index].sourceID, wall: merged)
            } else { result.append(surface) }
        }
        return result
    }

    private static func uprightWall(_ surface: SceneSurface) -> Wall? {
        let matrix = surface.mapFromSurface, size = surface.measuredDimensionsM
        guard abs(matrix[1]) < 0.001, matrix[5] > 0.999, abs(matrix[9]) < 0.001,
              size[0] > size[2], size[1] > 0 else { return nil }
        let tangent = Point(Double(matrix[0]), Double(matrix[2]))
        let normal = Point(Double(matrix[8]), Double(matrix[10]))
        let center = Point(Double(matrix[12]), Double(matrix[14]))
        let along = simd_dot(tangent, center), y = Double(matrix[13])
        return Wall(rectangle: Rectangle(min: Point(along - Double(size[0]) / 2, y - Double(size[1]) / 2),
                                        max: Point(along + Double(size[0]) / 2, y + Double(size[1]) / 2)),
                    tangent: tangent, normal: normal, offset: simd_dot(normal, center))
    }

    private static func mapPoint(_ p: [Float], _ m: [Float]) -> SIMD3<Double> {
        SIMD3((0..<3).map { row in Double(m[row]) * Double(p[0]) + Double(m[4 + row]) * Double(p[1])
            + Double(m[8 + row]) * Double(p[2]) + Double(m[12 + row]) })
    }

    private static func worldCorners(_ surface: SceneSurface) -> [SIMD3<Double>] {
        (0..<8).map { corner in
            mapPoint((0..<3).map { axis in surface.measuredDimensionsM[axis] * (corner & (1 << axis) == 0 ? -0.5 : 0.5) },
                     surface.mapFromSurface)
        }
    }

    private static func worldBounds(_ surface: SceneSurface) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        let corners = worldCorners(surface)
        return (corners.dropFirst().reduce(corners[0], simd_min), corners.dropFirst().reduce(corners[0], simd_max))
    }

    private static func contains(_ point: SIMD3<Double>, object: SceneObject, inset: Double) -> Bool {
        (0..<3).allSatisfy { point[$0] >= Double(object.obstacleBounds.min[$0]) + inset
            && point[$0] <= Double(object.obstacleBounds.max[$0]) - inset }
    }

    private static func cellBounds(_ cell: Cell, step: Point) -> Rectangle {
        Rectangle(min: Point(Double(cell.x) * step.x, Double(cell.y) * step.y),
                  max: Point(Double(cell.x + 1) * step.x, Double(cell.y + 1) * step.y))
    }

    private static func rectangle(_ points: [Point]) -> Rectangle {
        Rectangle(min: points.dropFirst().reduce(points[0], simd_min), max: points.dropFirst().reduce(points[0], simd_max))
    }

    private static func signedArea(_ polygon: [Point]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        let origin = polygon[0]
        return polygon.indices.reduce(0.0) { sum, index in
            sum + cross(polygon[index] - origin, polygon[(index + 1) % polygon.count] - origin) / 2
        }
    }

    private static func cross(_ a: Point, _ b: Point) -> Double { a.x * b.y - a.y * b.x }
    private static func counterclockwise(_ polygon: [Point]) -> [Point] { signedArea(polygon) >= 0 ? polygon : polygon.reversed() }

    private static func clip(_ polygon: [Point], a: Point, b: Point, keepingInside: Bool) -> [Point] {
        guard let last = polygon.last else { return [] }
        let edge = b - a
        func distance(_ point: Point) -> Double { cross(edge, point - a) }
        func inside(_ value: Double) -> Bool { keepingInside ? value >= 0 : value <= 0 }
        var previous = last, previousDistance = distance(last)
        var result: [Point] = []
        for current in polygon {
            let currentDistance = distance(current)
            if inside(currentDistance) != inside(previousDistance) {
                let t = previousDistance / (previousDistance - currentDistance)
                result.append(previous + (current - previous) * t)
            }
            if inside(currentDistance) { result.append(current) }
            previous = current
            previousDistance = currentDistance
        }
        var clean: [Point] = []
        for point in result where clean.last.map({ simd_length_squared($0 - point) > 1e-20 }) ?? true {
            clean.append(point)
        }
        if clean.count > 1, simd_length_squared(clean[0] - clean[clean.count - 1]) <= 1e-20 { clean.removeLast() }
        return clean
    }

    private static func intersect(_ polygon: [Point], with mask: [Point]) -> [Point] {
        var result = polygon
        for index in mask.indices {
            result = clip(result, a: mask[index], b: mask[(index + 1) % mask.count], keepingInside: true)
            if result.count < 3 { return [] }
        }
        return result
    }

    private static func subtract(_ mask: [Point], from polygon: [Point]) -> [[Point]] {
        var inside = polygon
        var outside: [[Point]] = []
        for index in mask.indices {
            let a = mask[index], b = mask[(index + 1) % mask.count]
            if simd_length_squared(b - a) <= 1e-20 { continue }
            let portion = clip(inside, a: a, b: b, keepingInside: false)
            if portion.count >= 3, abs(signedArea(portion)) > 1e-12 { outside.append(portion) }
            inside = clip(inside, a: a, b: b, keepingInside: true)
            if inside.count < 3 { break }
        }
        return outside
    }

    private static func overlaps(_ a: Rectangle, _ b: Rectangle) -> Bool {
        min(a.max.x, b.max.x) - max(a.min.x, b.min.x) > 1e-7
            && min(a.max.y, b.max.y) - max(a.min.y, b.min.y) > 1e-7
    }

    private static func polygonsOverlap(_ a: [Point], _ b: [Point]) -> Bool {
        if a.contains(where: { near($0, polygon: b, distance: 0.000001) })
            || b.contains(where: { near($0, polygon: a, distance: 0.000001) }) { return true }
        for i in a.indices {
            for j in b.indices {
                let p = a[i], r = a[(i + 1) % a.count] - p
                let q = b[j], s = b[(j + 1) % b.count] - q
                let denominator = cross(r, s)
                if abs(denominator) <= 1e-10 { continue }
                let t = cross(q - p, s) / denominator, u = cross(q - p, r) / denominator
                if (0...1).contains(t), (0...1).contains(u) { return true }
            }
        }
        return false
    }

    private static func near(_ point: Point, polygon: [Point], distance: Double) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count], edge = b - a
            let length = simd_length_squared(edge)
            if length > 1e-12 {
                let t = min(1, max(0, simd_dot(point - a, edge) / length))
                if simd_length_squared(point - a - edge * t) <= distance * distance { return true }
            }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }

    private static func rectangleDistance(_ a: Rectangle, _ b: Rectangle) -> Double {
        hypot(max(0, max(a.min.x - b.max.x, b.min.x - a.max.x)), max(0, max(a.min.y - b.max.y, b.min.y - a.max.y)))
    }

    private static func uniqueID(_ prefix: String, used: inout Set<String>) -> String {
        var id = prefix, suffix = 1
        while used.contains(id) { id = "\(prefix)-\(suffix)"; suffix += 1 }
        used.insert(id)
        return id
    }
}
