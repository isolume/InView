import Foundation

/// Cuts measured room footprints out of an exterior without expanding the mapped area.
/// Results are disjoint convex pieces, suitable for individual native map extrusions.
public enum BuildingFootprintCutaway {
    public static func subtract(
        mapped: [[SIMD2<Float>]],
        from exterior: [SIMD2<Float>],
        holes: [[SIMD2<Float>]] = []
    ) throws -> [[SIMD2<Float>]] {
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
        let outer = try polygon(exterior, maximumVertices: Limits.polygonVertices, tolerance: tolerance)
        let courtyards = try holes.map { try polygon($0, maximumVertices: Limits.polygonVertices, tolerance: tolerance) }
        let rooms = try mapped.map { points -> [Point] in
            let room = try polygon(points, maximumVertices: Limits.maskVertices, tolerance: tolerance)
            guard convex(room, tolerance: tolerance) else { throw BuildingFootprintCutawayError.nonConvexMappedPolygon }
            return room
        }
        try validateHoles(courtyards, within: outer, tolerance: tolerance)

        var budget = WorkBudget()
        var pieces = try convexPieces(outer, tolerance: tolerance, budget: &budget)
        var masks: [[Point]] = []
        for courtyard in courtyards {
            masks.append(contentsOf: try convexPieces(courtyard, tolerance: tolerance, budget: &budget))
        }
        masks.append(contentsOf: rooms)
        for mask in masks {
            var remainder: [[Point]] = []
            for piece in pieces {
                let cut = try subtract(mask, from: piece, tolerance: tolerance, budget: &budget)
                guard remainder.count + cut.count <= Limits.pieces else {
                    throw BuildingFootprintCutawayError.geometryTooComplex
                }
                remainder.append(contentsOf: cut)
            }
            pieces = remainder
            if pieces.isEmpty { break }
        }

        return try pieces.compactMap { piece in
            // Normalize again at the public Float boundary so rounding cannot emit repeated vertices.
            let values = piece.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            let rounded = cleaned(values.map { Point(Double($0.x), Double($0.y)) }, tolerance: tolerance)
            guard rounded.count >= 3, area(rounded) > tolerance * tolerance else { return nil }
            guard rounded.count <= Limits.pieceVertices else { throw BuildingFootprintCutawayError.geometryTooComplex }
            return rounded.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        }
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
