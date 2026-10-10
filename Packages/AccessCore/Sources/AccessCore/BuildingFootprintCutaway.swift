import Foundation

/// Cuts measured room footprints out of an exterior without expanding the mapped area.
/// Boundary regions preserve courtyard openings without introducing walls between triangulated pieces.
public enum BuildingFootprintCutaway {
    /// A connected exterior with its enclosed cutouts. Rings are open, with the exterior
    /// counterclockwise and holes clockwise, matching GeoJSON's winding convention.
    public struct Region: Equatable, Sendable {
        public let exterior: [SIMD2<Float>]
        public let holes: [[SIMD2<Float>]]

        public init(exterior: [SIMD2<Float>], holes: [[SIMD2<Float>]] = []) {
            self.exterior = exterior
            self.holes = holes
        }
    }

    /// Returns convex pieces for callers that need to triangulate the remaining footprint.
    public static func subtract(
        mapped: [[SIMD2<Float>]],
        from exterior: [SIMD2<Float>],
        holes: [[SIMD2<Float>]] = []
    ) throws -> [[SIMD2<Float>]] {
        var budget = WorkBudget()
        let (pieces, tolerance) = try subtractPieces(mapped: mapped, from: exterior, holes: holes, budget: &budget)
        return try pieces.compactMap { piece in
            // Normalize again at the public Float boundary so rounding cannot emit repeated vertices.
            let rounded = roundedRing(piece, tolerance: tolerance)
            guard rounded.count >= 3, area(rounded) > tolerance * tolerance else { return nil }
            guard rounded.count <= Limits.pieceVertices else { throw BuildingFootprintCutawayError.geometryTooComplex }
            return rounded.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        }
    }

    /// Returns actual connected boundaries rather than individual subtraction fragments.
    /// Extruding one region keeps internal triangle edges from becoming visible walls.
    public static func subtractRegions(
        mapped: [[SIMD2<Float>]],
        from exterior: [SIMD2<Float>],
        holes: [[SIMD2<Float>]] = []
    ) throws -> [Region] {
        var budget = WorkBudget()
        let (pieces, tolerance) = try subtractPieces(mapped: mapped, from: exterior, holes: holes,
                                                     allowConcaveMasks: true, budget: &budget)
        return try boundaryRegions(pieces, tolerance: tolerance, budget: &budget)
    }

    /// Combines measured floor sections into contiguous surfaces with no overlap.
    /// Enclosed unmapped gaps remain holes, and disconnected floors remain separate regions.
    public static func unionRegions(_ polygons: [[SIMD2<Float>]]) throws -> [Region] {
        guard polygons.count <= Limits.masks,
              polygons.reduce(0, { $0 + $1.count }) <= Limits.totalVertices else {
            throw BuildingFootprintCutawayError.geometryTooComplex
        }
        let allPoints = polygons.flatMap { $0 }
        guard allPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw BuildingFootprintCutawayError.invalidPolygon
        }
        guard allPoints.allSatisfy({ abs($0.x) <= Limits.coordinateMagnitude && abs($0.y) <= Limits.coordinateMagnitude }) else {
            throw BuildingFootprintCutawayError.geometryTooComplex
        }
        let scale = allPoints.reduce(1.0) { max($0, abs(Double($1.x)), abs(Double($1.y))) }
        let tolerance = 1e-9 * scale
        var budget = WorkBudget()
        var covered: [[Point]] = []
        var pieces: [[Point]] = []
        let rings = try polygons.map {
            canonicalRing(try polygon($0, maximumVertices: Limits.polygonVertices, tolerance: tolerance))
        }.sorted(by: ringPrecedes)
        for ring in rings {
            let triangles = try convexPieces(ring, tolerance: tolerance, budget: &budget)
            for triangle in triangles {
                var additional = [triangle]
                for mask in covered {
                    var remainder: [[Point]] = []
                    for piece in additional {
                        try budget.consume(mask.count + piece.count)
                        remainder.append(contentsOf: try subtract(mask, from: piece, tolerance: tolerance, budget: &budget))
                        guard remainder.count + pieces.count <= Limits.pieces else {
                            throw BuildingFootprintCutawayError.geometryTooComplex
                        }
                    }
                    additional = remainder
                    if additional.isEmpty { break }
                }
                guard pieces.count + additional.count <= Limits.pieces else { throw BuildingFootprintCutawayError.geometryTooComplex }
                pieces.append(contentsOf: additional)
            }
            guard covered.count + triangles.count <= Limits.pieces else { throw BuildingFootprintCutawayError.geometryTooComplex }
            covered.append(contentsOf: triangles)
        }
        return try boundaryRegions(pieces, tolerance: tolerance, budget: &budget)
    }

    private static func subtractPieces(
        mapped: [[SIMD2<Float>]], from exterior: [SIMD2<Float>], holes: [[SIMD2<Float>]],
        allowConcaveMasks: Bool = false, budget: inout WorkBudget
    ) throws -> ([[Point]], Double) {
        guard mapped.count <= Limits.masks, holes.count <= Limits.holes,
              exterior.count + holes.reduce(0, { $0 + $1.count }) + mapped.reduce(0, { $0 + $1.count }) <= Limits.totalVertices else {
            throw BuildingFootprintCutawayError.geometryTooComplex
        }
        let allPoints = exterior + holes.flatMap { $0 } + mapped.flatMap { $0 }
        guard allPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw BuildingFootprintCutawayError.invalidPolygon
        }
        guard allPoints.allSatisfy({ abs($0.x) <= Limits.coordinateMagnitude && abs($0.y) <= Limits.coordinateMagnitude }) else {
            throw BuildingFootprintCutawayError.geometryTooComplex
        }
        // Work in Double to avoid accumulating Float error across sequential cuts.
        let scale = allPoints.reduce(1.0) { max($0, abs(Double($1.x)), abs(Double($1.y))) }
        let tolerance = 1e-9 * scale
        let validatedOuter = try polygon(exterior, maximumVertices: Limits.polygonVertices, tolerance: tolerance)
        let outer = allowConcaveMasks ? canonicalRing(validatedOuter) : validatedOuter
        let courtyards = try holes.map { points in
            let ring = try polygon(points, maximumVertices: Limits.polygonVertices, tolerance: tolerance)
            return allowConcaveMasks ? canonicalRing(ring) : ring
        }
        let rooms = try mapped.flatMap { points -> [[Point]] in
            let maximum = allowConcaveMasks ? Limits.polygonVertices : Limits.maskVertices
            let room = try polygon(points, maximumVertices: maximum, tolerance: tolerance)
            if allowConcaveMasks { return try convexPieces(canonicalRing(room), tolerance: tolerance, budget: &budget) }
            guard convex(room, tolerance: tolerance) else { throw BuildingFootprintCutawayError.nonConvexMappedPolygon }
            return [room]
        }
        guard rooms.count <= Limits.pieces else { throw BuildingFootprintCutawayError.geometryTooComplex }
        try validateHoles(courtyards, within: outer, tolerance: tolerance)

        var pieces = try convexPieces(outer, tolerance: tolerance, budget: &budget)
        var masks: [[Point]] = []
        for courtyard in courtyards {
            masks.append(contentsOf: try convexPieces(courtyard, tolerance: tolerance, budget: &budget))
        }
        masks.append(contentsOf: rooms)
        if allowConcaveMasks { masks = masks.map(canonicalRing).sorted(by: ringPrecedes) }
        for mask in masks {
            var remainder: [[Point]] = []
            for piece in pieces {
                if allowConcaveMasks { try budget.consume(mask.count + piece.count) }
                let cut = try subtract(mask, from: piece, tolerance: tolerance, budget: &budget)
                guard remainder.count + cut.count <= Limits.pieces else {
                    throw BuildingFootprintCutawayError.geometryTooComplex
                }
                remainder.append(contentsOf: cut)
            }
            pieces = remainder
            if pieces.isEmpty { break }
        }

        return (pieces, tolerance)
    }

    private typealias Point = SIMD2<Double>

    private enum Limits {
        static let polygonVertices = 256
        static let maskVertices = 16
        static let masks = 128
        static let holes = 32
        static let totalVertices = 2_048
        static let pieces = 1_024
        static let pieceVertices = 64
        static let boundaryEdges = 16_384
        static let work = 2_000_000
        static let coordinateMagnitude: Float = 100_000
    }

    private struct WorkBudget {
        var spent = 0
        mutating func consume(_ amount: Int) throws {
            guard amount <= Limits.work - spent else { throw BuildingFootprintCutawayError.geometryTooComplex }
            spent += amount
        }
    }

    private struct Edge: Hashable {
        let start: Int
        let end: Int
        var reversed: Edge { Edge(start: end, end: start) }
    }

    private struct VertexCell: Hashable {
        let x: Int64
        let y: Int64
    }

    /// Shared intersections can differ by a few Double ulps after independent clipping.
    /// Nearby-cell matching joins those intersections before any topology is assembled.
    private struct VertexRegistry {
        var points: [Point] = []
        var cells: [VertexCell: [Int]] = [:]
        let tolerance: Double

        mutating func identify(_ point: Point, budget: inout WorkBudget) throws -> Int {
            let cell = VertexCell(x: Int64(floor(point.x / tolerance)), y: Int64(floor(point.y / tolerance)))
            for x in (cell.x - 1)...(cell.x + 1) {
                for y in (cell.y - 1)...(cell.y + 1) {
                    let candidates = cells[VertexCell(x: x, y: y)] ?? []
                    try budget.consume(candidates.count + 1)
                    if let index = candidates.first(where: { distance(points[$0], point) <= tolerance }) { return index }
                }
            }
            let index = points.count
            points.append(point)
            cells[cell, default: []].append(index)
            return index
        }
    }

    private static func boundaryRegions(
        _ pieces: [[Point]], tolerance: Double, budget: inout WorkBudget
    ) throws -> [Region] {
        guard !pieces.isEmpty else { return [] }
        let pointCount = pieces.reduce(0) { $0 + $1.count }
        guard pointCount <= Limits.boundaryEdges else { throw BuildingFootprintCutawayError.geometryTooComplex }
        try budget.consume(pointCount)
        var registry = VertexRegistry(tolerance: tolerance)
        var identifiers: [Point: Int] = [:]
        // Sorting makes intersection snapping independent of the order rooms were cut.
        for point in pieces.flatMap({ $0 }).sorted(by: pointPrecedes) where identifiers[point] == nil {
            identifiers[point] = try registry.identify(point, budget: &budget)
        }
        let points = registry.points
        var edges: Set<Edge> = []
        for piece in pieces {
            let vertices = piece.map { identifiers[$0]! }
            for i in vertices.indices {
                let edge = Edge(start: vertices[i], end: vertices[(i + 1) % vertices.count])
                if edge.start != edge.end { try addBoundary(edge, to: &edges) }
            }
        }

        // A clipped triangle can meet only part of another triangle's edge. Split at
        // every surviving endpoint before cancellation, so those T junctions disappear too.
        let endpoints = Set(edges.flatMap { [$0.start, $0.end] })
        let byX = endpoints.sorted { points[$0].x == points[$1].x ? $0 < $1 : points[$0].x < points[$1].x }
        let byY = endpoints.sorted { points[$0].y == points[$1].y ? $0 < $1 : points[$0].y < points[$1].y }
        var boundary: Set<Edge> = []
        for edge in edges.sorted(by: edgePrecedes) {
            let a = points[edge.start], b = points[edge.end]
            let xRange = coordinateRange(byX, points: points, axis: 0,
                                         minimum: min(a.x, b.x) - tolerance, maximum: max(a.x, b.x) + tolerance)
            let yRange = coordinateRange(byY, points: points, axis: 1,
                                         minimum: min(a.y, b.y) - tolerance, maximum: max(a.y, b.y) + tolerance)
            let candidates = xRange.count <= yRange.count ? byX[xRange] : byY[yRange]
            try budget.consume(candidates.count)
            let direction = b - a
            let lengthSquared = dot(direction, direction)
            var splits: [(Int, Double)] = [(edge.start, 0), (edge.end, 1)]
            for vertex in candidates where vertex != edge.start && vertex != edge.end {
                let point = points[vertex]
                guard onSegment(point, a, b, tolerance: tolerance) else { continue }
                let fraction = dot(point - a, direction) / lengthSquared
                if fraction > 0 && fraction < 1 { splits.append((vertex, fraction)) }
            }
            splits.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            for i in 1..<splits.count {
                try addBoundary(Edge(start: splits[i - 1].0, end: splits[i].0), to: &boundary)
            }
            guard boundary.count <= Limits.boundaryEdges else { throw BuildingFootprintCutawayError.geometryTooComplex }
        }
        guard !boundary.isEmpty else { return [] }

        let ordered = boundary.sorted(by: edgePrecedes)
        let outgoing = Dictionary(grouping: ordered, by: \.start)
        var unvisited = boundary
        var rings: [[Point]] = []
        for first in ordered where unvisited.contains(first) {
            var ring: [Point] = []
            var current = first
            while true {
                try budget.consume(1)
                guard unvisited.remove(current) != nil else { throw BuildingFootprintCutawayError.invalidPolygon }
                ring.append(points[current.start])
                if current.end == first.start { break }
                let candidates = (outgoing[current.end] ?? []).filter { unvisited.contains($0) }
                guard !candidates.isEmpty else { throw BuildingFootprintCutawayError.invalidPolygon }
                // Keep filled area on the left, including where independent regions touch
                // at a vertex. Taking the leftmost continuation avoids a figure-eight ring.
                let incoming = points[current.end] - points[current.start]
                current = candidates.max { first, second in
                    let firstTurn = turn(incoming, points[first.end] - points[first.start])
                    let secondTurn = turn(incoming, points[second.end] - points[second.start])
                    return firstTurn == secondTurn ? edgePrecedes(second, first) : firstTurn < secondTurn
                }!
            }
            for loop in simpleLoops(ring) {
                let normalized = roundedRing(loop, tolerance: tolerance)
                if normalized.count >= 3 && abs(area(normalized)) > tolerance * tolerance {
                    rings.append(canonicalRing(normalized))
                }
            }
        }

        let outers = rings.filter { area($0) > 0 }.sorted(by: ringPrecedes)
        let holes = rings.filter { area($0) < 0 }.sorted(by: ringPrecedes)
        var assigned = Array(repeating: [[Point]](), count: outers.count)
        for hole in holes {
            var containing: Int?
            var containingArea = Double.infinity
            for i in outers.indices {
                try budget.consume(outers[i].count)
                if inside(hole[0], polygon: outers[i], tolerance: tolerance) {
                    let size = area(outers[i])
                    if size < containingArea { containing = i; containingArea = size }
                }
            }
            guard let containing else { throw BuildingFootprintCutawayError.invalidPolygon }
            assigned[containing].append(hole)
        }
        return outers.indices.map { i in
            Region(exterior: outers[i].map(floatPoint), holes: assigned[i].map { $0.map(floatPoint) })
        }
    }

    private static func addBoundary(_ edge: Edge, to edges: inout Set<Edge>) throws {
        if edges.remove(edge.reversed) == nil {
            guard edges.insert(edge).inserted else { throw BuildingFootprintCutawayError.invalidPolygon }
        }
    }

    private static func coordinateRange(
        _ vertices: [Int], points: [Point], axis: Int, minimum: Double, maximum: Double
    ) -> Range<Int> {
        func lowerBound(_ value: Double, inclusive: Bool) -> Int {
            var lower = 0, upper = vertices.count
            while lower < upper {
                let middle = (lower + upper) / 2
                let coordinate = points[vertices[middle]][axis]
                if coordinate < value || (!inclusive && coordinate == value) { lower = middle + 1 }
                else { upper = middle }
            }
            return lower
        }
        return lowerBound(minimum, inclusive: true)..<lowerBound(maximum, inclusive: false)
    }

    private static func turn(_ incoming: Point, _ outgoing: Point) -> Double {
        atan2(incoming.x * outgoing.y - incoming.y * outgoing.x, dot(incoming, outgoing))
    }

    /// A cutout can touch another cutout or the exterior at exactly one vertex.
    /// Split that boundary walk into simple loops before assigning holes, instead of
    /// publishing a self-touching figure-eight ring to the map renderer.
    private static func simpleLoops(_ ring: [Point]) -> [[Point]] {
        guard let first = ring.first else { return [] }
        var path: [Point] = []
        var indices: [Point: Int] = [:]
        var loops: [[Point]] = []
        for point in ring + [first] {
            if let start = indices[point] {
                let loop = Array(path[start...])
                if loop.count >= 3 { loops.append(loop) }
                for removed in loop { indices.removeValue(forKey: removed) }
                path.removeSubrange(start...)
            }
            indices[point] = path.count
            path.append(point)
        }
        return loops
    }

    private static func roundedRing(_ points: [Point], tolerance: Double) -> [Point] {
        // Remove Double-precision collinear intersections before Float rounding can
        // turn them into tiny bends along an otherwise straight measured boundary.
        let simplified = cleaned(points, tolerance: tolerance)
        return cleaned(simplified.map { Point(Double(Float($0.x)), Double(Float($0.y))) }, tolerance: tolerance)
    }

    private static func floatPoint(_ point: Point) -> SIMD2<Float> {
        SIMD2<Float>(point.x == 0 ? 0 : Float(point.x), point.y == 0 ? 0 : Float(point.y))
    }

    private static func pointPrecedes(_ first: Point, _ second: Point) -> Bool {
        first.x == second.x ? first.y < second.y : first.x < second.x
    }

    private static func edgePrecedes(_ first: Edge, _ second: Edge) -> Bool {
        first.start == second.start ? first.end < second.end : first.start < second.start
    }

    private static func canonicalRing(_ ring: [Point]) -> [Point] {
        let first = ring.indices.min { pointPrecedes(ring[$0], ring[$1]) }!
        return Array(ring[first...] + ring[..<first])
    }

    private static func ringPrecedes(_ first: [Point], _ second: [Point]) -> Bool {
        for (a, b) in zip(first, second) where a != b { return pointPrecedes(a, b) }
        return first.count < second.count
    }

    private static func polygon(_ input: [SIMD2<Float>], maximumVertices: Int, tolerance: Double) throws -> [Point] {
        guard input.count <= maximumVertices + 1 else { throw BuildingFootprintCutawayError.geometryTooComplex }
        var points = input.map { Point(Double($0.x), Double($0.y)) }
        if points.count > 1, distance(points[0], points[points.count - 1]) <= tolerance { points.removeLast() }
        guard points.count >= 3, points.count <= maximumVertices else {
            throw BuildingFootprintCutawayError.invalidPolygon
        }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], c = points[(i + 2) % points.count]
            guard distance(a, b) > tolerance else { throw BuildingFootprintCutawayError.invalidPolygon }
            // Adjacent collinear edges may continue a straight boundary but must not double back.
            if abs(side(c, a, b)) <= tolerance, dot(a - b, c - b) > 0 {
                throw BuildingFootprintCutawayError.invalidPolygon
            }
            for j in points.indices where j > i + 1 && !(i == 0 && j == points.count - 1) {
                if segmentsIntersect(a, b, points[j], points[(j + 1) % points.count], tolerance: tolerance) {
                    throw BuildingFootprintCutawayError.invalidPolygon
                }
            }
        }
        points = cleaned(points, tolerance: tolerance)
        let signedArea = area(points)
        guard points.count >= 3, abs(signedArea) > tolerance * tolerance else {
            throw BuildingFootprintCutawayError.invalidPolygon
        }
        return signedArea > 0 ? points : points.reversed()
    }

    private static func validateHoles(_ holes: [[Point]], within outer: [Point], tolerance: Double) throws {
        for i in holes.indices {
            let hole = holes[i]
            guard hole.allSatisfy({ inside($0, polygon: outer, tolerance: tolerance) }),
                  !boundariesIntersect(hole, outer, tolerance: tolerance) else {
                throw BuildingFootprintCutawayError.invalidHole
            }
            for j in holes.indices where j < i {
                if boundariesIntersect(hole, holes[j], tolerance: tolerance)
                    || inside(hole[0], polygon: holes[j], tolerance: tolerance)
                    || inside(holes[j][0], polygon: hole, tolerance: tolerance) {
                    throw BuildingFootprintCutawayError.invalidHole
                }
            }
        }
    }

    private static func convexPieces(_ points: [Point], tolerance: Double, budget: inout WorkBudget) throws -> [[Point]] {
        if points.count <= Limits.pieceVertices && convex(points, tolerance: tolerance) { return [points] }
        var remaining = Array(points.indices)
        var triangles: [[Point]] = []
        while remaining.count > 3 {
            var ear: Int?
            for i in remaining.indices {
                let a = points[remaining[(i + remaining.count - 1) % remaining.count]]
                let b = points[remaining[i]]
                let c = points[remaining[(i + 1) % remaining.count]]
                guard side(c, a, b) > tolerance else { continue }
                try budget.consume(remaining.count)
                let triangle = [a, b, c]
                let occupied = remaining.contains { index in
                    let point = points[index]
                    return point != a && point != b && point != c && triangleContains(point, triangle, tolerance: tolerance)
                }
                if !occupied { ear = i; triangles.append(triangle); break }
            }
            guard let ear else { throw BuildingFootprintCutawayError.invalidPolygon }
            remaining.remove(at: ear)
        }
        let last = remaining.map { points[$0] }
        guard area(last) > tolerance * tolerance else { throw BuildingFootprintCutawayError.invalidPolygon }
        triangles.append(last)
        return triangles
    }

    private static func subtract(
        _ mask: [Point], from piece: [Point], tolerance: Double, budget: inout WorkBudget
    ) throws -> [[Point]] {
        guard boundsOverlap(mask, piece, tolerance: tolerance) else { return [piece] }
        var remaining = piece
        var exterior: [[Point]] = []
        // Each emitted piece lies outside this edge but inside all previous mask edges.
        // Their interiors cannot overlap; only the final fully inside remainder is discarded.
        for i in mask.indices {
            let a = mask[i], b = mask[(i + 1) % mask.count]
            let outside = try clipped(remaining, a: a, b: b, keepInside: false, tolerance: tolerance, budget: &budget)
            if outside.count >= 3 { exterior.append(outside) }
            remaining = try clipped(remaining, a: a, b: b, keepInside: true, tolerance: tolerance, budget: &budget)
            if remaining.count < 3 { break }
        }
        return exterior
    }

    private static func clipped(
        _ points: [Point], a: Point, b: Point, keepInside: Bool, tolerance: Double, budget: inout WorkBudget
    ) throws -> [Point] {
        try budget.consume(points.count)
        guard !points.isEmpty else { return [] }
        func signedDistance(_ point: Point) -> Double {
            let value = side(point, a, b)
            let snapped = abs(value) <= tolerance ? 0 : value
            return keepInside ? snapped : -snapped
        }
        var result: [Point] = []
        var previous = points[points.count - 1]
        var previousDistance = signedDistance(previous)
        for point in points {
            let currentDistance = signedDistance(point)
            if (currentDistance >= 0) != (previousDistance >= 0) {
                let t = previousDistance / (previousDistance - currentDistance)
                result.append(previous + (point - previous) * t)
            }
            if currentDistance >= 0 { result.append(point) }
            previous = point
            previousDistance = currentDistance
        }
        result = cleaned(result, tolerance: tolerance)
        guard result.count <= Limits.pieceVertices else { throw BuildingFootprintCutawayError.geometryTooComplex }
        return result.count >= 3 && area(result) > tolerance * tolerance ? result : []
    }

    private static func cleaned(_ points: [Point], tolerance: Double) -> [Point] {
        var result: [Point] = []
        for point in points where result.last.map({ distance($0, point) > tolerance }) ?? true { result.append(point) }
        if result.count > 1, distance(result[0], result[result.count - 1]) <= tolerance { result.removeLast() }
        var changed = true
        while changed && result.count > 3 {
            changed = false
            for i in result.indices {
                let previous = result[(i + result.count - 1) % result.count], next = result[(i + 1) % result.count]
                if abs(side(result[i], previous, next)) <= tolerance && dot(result[i] - previous, result[i] - next) <= 0 {
                    result.remove(at: i); changed = true; break
                }
            }
        }
        return result
    }

    private static func convex(_ points: [Point], tolerance: Double) -> Bool {
        points.indices.allSatisfy {
            side(points[($0 + 2) % points.count], points[$0], points[($0 + 1) % points.count]) >= -tolerance
        }
    }

    private static func triangleContains(_ point: Point, _ triangle: [Point], tolerance: Double) -> Bool {
        triangle.indices.allSatisfy { side(point, triangle[$0], triangle[($0 + 1) % 3]) >= -tolerance }
    }

    private static func inside(_ point: Point, polygon: [Point], tolerance: Double) -> Bool {
        var result = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if onSegment(point, a, b, tolerance: tolerance) { return true }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
        }
        return result
    }

    private static func boundariesIntersect(_ first: [Point], _ second: [Point], tolerance: Double) -> Bool {
        first.indices.contains { i in
            second.indices.contains { j in
                segmentsIntersect(first[i], first[(i + 1) % first.count], second[j], second[(j + 1) % second.count], tolerance: tolerance)
            }
        }
    }

    private static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point, tolerance: Double) -> Bool {
        let cSide = side(c, a, b), dSide = side(d, a, b)
        let aSide = side(a, c, d), bSide = side(b, c, d)
        if ((cSide > tolerance && dSide < -tolerance) || (cSide < -tolerance && dSide > tolerance))
            && ((aSide > tolerance && bSide < -tolerance) || (aSide < -tolerance && bSide > tolerance)) { return true }
        return onSegment(c, a, b, tolerance: tolerance) || onSegment(d, a, b, tolerance: tolerance)
            || onSegment(a, c, d, tolerance: tolerance) || onSegment(b, c, d, tolerance: tolerance)
    }

    private static func onSegment(_ point: Point, _ a: Point, _ b: Point, tolerance: Double) -> Bool {
        abs(side(point, a, b)) <= tolerance
            && point.x >= min(a.x, b.x) - tolerance && point.x <= max(a.x, b.x) + tolerance
            && point.y >= min(a.y, b.y) - tolerance && point.y <= max(a.y, b.y) + tolerance
    }

    private static func boundsOverlap(_ first: [Point], _ second: [Point], tolerance: Double) -> Bool {
        let minFirst = Point(first.map(\.x).min()!, first.map(\.y).min()!)
        let maxFirst = Point(first.map(\.x).max()!, first.map(\.y).max()!)
        let minSecond = Point(second.map(\.x).min()!, second.map(\.y).min()!)
        let maxSecond = Point(second.map(\.x).max()!, second.map(\.y).max()!)
        return maxFirst.x > minSecond.x + tolerance && maxSecond.x > minFirst.x + tolerance
            && maxFirst.y > minSecond.y + tolerance && maxSecond.y > minFirst.y + tolerance
    }

    private static func area(_ points: [Point]) -> Double {
        guard points.count >= 3 else { return 0 }
        let origin = points[0]
        return (1..<(points.count - 1)).reduce(0.0) { sum, i in
            let a = points[i] - origin, b = points[i + 1] - origin
            return sum + (a.x * b.y - a.y * b.x) / 2
        }
    }

    private static func side(_ point: Point, _ a: Point, _ b: Point) -> Double {
        let edge = b - a
        let length = sqrt(dot(edge, edge))
        guard length > 0 else { return 0 }
        let offset = point - a
        return (edge.x * offset.y - edge.y * offset.x) / length
    }

    private static func dot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }
    private static func distance(_ a: Point, _ b: Point) -> Double { sqrt(dot(a - b, a - b)) }
}

public enum BuildingFootprintCutawayError: Error, Equatable, Sendable {
    case invalidPolygon
    case invalidHole
    case nonConvexMappedPolygon
    case geometryTooComplex
}
