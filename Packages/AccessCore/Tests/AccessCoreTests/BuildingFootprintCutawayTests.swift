import Foundation
import Testing
@testable import AccessCore

private typealias CutawayPoint = SIMD2<Float>

private func cutawayRectangle(_ minX: Float, _ minY: Float, _ maxX: Float, _ maxY: Float) -> [CutawayPoint] {
    [[minX, minY], [maxX, minY], [maxX, maxY], [minX, maxY]]
}

private func cutawayArea(_ points: [CutawayPoint]) -> Double {
    abs(points.indices.reduce(0.0) { sum, i in
        let a = points[i], b = points[(i + 1) % points.count]
        return sum + Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x)
    } / 2)
}

private func cutawayContains(_ point: CutawayPoint, _ polygon: [CutawayPoint]) -> Bool {
    var inside = false
    for i in polygon.indices {
        let a = polygon[i], b = polygon[(i + 1) % polygon.count]
        if (a.y > point.y) != (b.y > point.y),
           point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
    }
    return inside
}

private func cutawayNearBoundary(_ point: CutawayPoint, _ polygon: [CutawayPoint]) -> Bool {
    polygon.indices.contains { i in
        let a = polygon[i], b = polygon[(i + 1) % polygon.count], edge = b - a, offset = point - a
        let cross = edge.x * offset.y - edge.y * offset.x
        return abs(cross) < 0.0001 && point.x >= min(a.x, b.x) - 0.0001 && point.x <= max(a.x, b.x) + 0.0001
            && point.y >= min(a.y, b.y) - 0.0001 && point.y <= max(a.y, b.y) + 0.0001
    }
}

/// Checks the remainder independently by its area and dense interior membership.
private func expectCutaway(
    _ pieces: [[CutawayPoint]], exterior: [CutawayPoint], holes: [[CutawayPoint]] = [],
    mapped: [[CutawayPoint]], area: Double
) {
    #expect(abs(pieces.reduce(0.0, { $0 + cutawayArea($1) }) - area) < 0.0001)
    for piece in pieces {
        #expect(piece.count >= 3 && piece.count <= 64)
        #expect(piece.first != piece.last)
        for i in piece.indices {
            let a = piece[(i + 1) % piece.count] - piece[i]
            let b = piece[(i + 2) % piece.count] - piece[(i + 1) % piece.count]
            #expect(a.x * b.y - a.y * b.x >= -0.0001)
        }
    }
    let minX = exterior.map(\.x).min()!, maxX = exterior.map(\.x).max()!
    let minY = exterior.map(\.y).min()!, maxY = exterior.map(\.y).max()!
    for x in 0..<31 {
        for y in 0..<29 {
            let point = CutawayPoint(minX + (maxX - minX) * (Float(x) + 0.37) / 31,
                                     minY + (maxY - minY) * (Float(y) + 0.61) / 29)
            if ([exterior] + holes + mapped).contains(where: { cutawayNearBoundary(point, $0) }) { continue }
            let expected = cutawayContains(point, exterior)
                && !holes.contains(where: { cutawayContains(point, $0) })
                && !mapped.contains(where: { cutawayContains(point, $0) })
            let count = pieces.filter { cutawayContains(point, $0) }.count
            #expect((count > 0) == expected)
            if !pieces.contains(where: { cutawayNearBoundary(point, $0) }) { #expect(count <= 1) }
        }
    }
}

@Test func cutawayPreservesCourtyardsAndUnmappedExterior() throws {
    let outer = cutawayRectangle(0, 0, 12, 12)
    let courtyard = cutawayRectangle(4, 4, 8, 8)
    let room = cutawayRectangle(0, 0, 6, 6)
    let result = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer, holes: [courtyard])
    // The 36 m² room overlaps 4 m² of courtyard, which must not be subtracted twice.
    expectCutaway(result, exterior: outer, holes: [courtyard], mapped: [room], area: 96)
    #expect(!result.contains { cutawayContains([5, 5], $0) })
    #expect(result.contains { cutawayContains([10, 10], $0) })
}

@Test func cutawayPreservesConcaveBuildingWingsWithoutUsingAHull() throws {
    let outer: [CutawayPoint] = [[0, 0], [8, 0], [8, 3], [3, 3], [3, 8], [0, 8]]
    let room = cutawayRectangle(0, 0, 5, 5)
    let result = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer)
    expectCutaway(result, exterior: outer, mapped: [room], area: 18)
    #expect(!result.contains { cutawayContains([6, 6], $0) })
    #expect(result.contains { cutawayContains([1, 7], $0) })
    #expect(result.contains { cutawayContains([7, 1], $0) })
}

@Test func cutawayClipsRoomsAtTheExteriorBoundary() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let room = cutawayRectangle(-2, 3, 4, 7)
    let result = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer)
    expectCutaway(result, exterior: outer, mapped: [room], area: 84)
}

@Test func cutawayClipsRotatedRoomsAlongTheirMeasuredEdges() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let room: [CutawayPoint] = [[5, -1], [11, 5], [5, 11], [-1, 5]]
    let result = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer)
    // The 72 m² rotated square extends past each side in a 1 m² triangle.
    expectCutaway(result, exterior: outer, mapped: [room], area: 32)
    #expect(result.contains { cutawayContains([1, 1], $0) })
    #expect(!result.contains { cutawayContains([5, 5], $0) })
}

@Test func cutawaySubtractsOverlappingRoomsOnlyOnce() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let rooms = [cutawayRectangle(1, 1, 6, 6), cutawayRectangle(4, 4, 9, 9)]
    let result = try BuildingFootprintCutaway.subtract(mapped: rooms, from: outer)
    let reverseOrder = try BuildingFootprintCutaway.subtract(mapped: rooms.reversed(), from: outer)
    expectCutaway(result, exterior: outer, mapped: rooms, area: 54)
    expectCutaway(reverseOrder, exterior: outer, mapped: rooms, area: 54)
}

@Test func cutawayRetainsUnscannedGapsBetweenIndependentRooms() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let rooms = [cutawayRectangle(1, 1, 4, 9), cutawayRectangle(6, 1, 9, 9)]
    let result = try BuildingFootprintCutaway.subtract(mapped: rooms, from: outer)
    expectCutaway(result, exterior: outer, mapped: rooms, area: 52)
    #expect(result.contains { cutawayContains([5, 5], $0) })
}

@Test func cutawayAcceptsEitherWindingAndClosedGeoJSONRings() throws {
    var outer = Array(cutawayRectangle(0, 0, 12, 12).reversed())
    outer.append(outer[0])
    var courtyard = cutawayRectangle(4, 4, 8, 8)
    courtyard.append(courtyard[0])
    var room = Array(cutawayRectangle(0, 0, 6, 6).reversed())
    room.append(room[0])
    let result = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer, holes: [courtyard])
    expectCutaway(result, exterior: Array(outer.dropLast()), holes: [Array(courtyard.dropLast())],
                  mapped: [Array(room.dropLast())], area: 96)
}

@Test func cutawayCanRemoveTheWholeExteriorOrLeaveItUnchanged() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    #expect(try BuildingFootprintCutaway.subtract(mapped: [cutawayRectangle(-1, -1, 11, 11)], from: outer).isEmpty)
    let room = cutawayRectangle(20, 20, 22, 22)
    let untouched = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer)
    #expect(untouched == [outer])
    expectCutaway(untouched, exterior: outer, mapped: [room], area: 100)
    #expect(try BuildingFootprintCutaway.subtract(mapped: [], from: outer) == [outer])
}

@Test func cutawayTriangulatesConcaveCourtyardHoles() throws {
    let outer = cutawayRectangle(0, 0, 12, 12)
    let courtyard: [CutawayPoint] = [[2, 2], [7, 2], [7, 4], [4, 4], [4, 7], [2, 7]]
    let room = cutawayRectangle(9, 8, 11, 11)
    let result = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer, holes: [courtyard])
    expectCutaway(result, exterior: outer, holes: [courtyard], mapped: [room], area: 122)
}

@Test func cutawayRejectsInvalidGeometryAsAWhole() {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let crossing: [CutawayPoint] = [[0, 0], [4, 4], [0, 4], [4, 0]]
    #expect(throws: BuildingFootprintCutawayError.invalidPolygon) {
        try BuildingFootprintCutaway.subtract(mapped: [], from: crossing)
    }
    #expect(throws: BuildingFootprintCutawayError.invalidPolygon) {
        try BuildingFootprintCutaway.subtract(mapped: [outer, crossing], from: outer)
    }
    #expect(throws: BuildingFootprintCutawayError.invalidPolygon) {
        try BuildingFootprintCutaway.subtract(mapped: [], from: [[0, 0], [1, 0], [2, 0]])
    }
    #expect(throws: BuildingFootprintCutawayError.invalidPolygon) {
        try BuildingFootprintCutaway.subtract(mapped: [[[.nan, 0], [1, 0], [1, 1]]], from: outer)
    }
    let concave: [CutawayPoint] = [[1, 1], [5, 1], [5, 2], [2, 2], [2, 5], [1, 5]]
    #expect(throws: BuildingFootprintCutawayError.nonConvexMappedPolygon) {
        try BuildingFootprintCutaway.subtract(mapped: [concave], from: outer)
    }
    #expect(throws: BuildingFootprintCutawayError.invalidHole) {
        try BuildingFootprintCutaway.subtract(mapped: [], from: outer, holes: [cutawayRectangle(9, 9, 11, 11)])
    }
    #expect(throws: BuildingFootprintCutawayError.invalidHole) {
        try BuildingFootprintCutaway.subtract(mapped: [], from: outer,
                                              holes: [cutawayRectangle(1, 1, 4, 4), cutawayRectangle(3, 3, 5, 5)])
    }
}

@Test func cutawayBoundsGeometryAndRendererCost() {
    let outer = cutawayRectangle(0, 0, 10, 10)
    #expect(throws: BuildingFootprintCutawayError.geometryTooComplex) {
        try BuildingFootprintCutaway.subtract(mapped: Array(repeating: cutawayRectangle(1, 1, 2, 2), count: 129), from: outer)
    }
    let manyVertices = (0..<300).map { index -> CutawayPoint in
        let angle = Float(index) / 300 * 2 * .pi
        return [cos(angle) * 5, sin(angle) * 5]
    }
    #expect(throws: BuildingFootprintCutawayError.geometryTooComplex) {
        try BuildingFootprintCutaway.subtract(mapped: [], from: manyVertices)
    }
    #expect(throws: BuildingFootprintCutawayError.geometryTooComplex) {
        try BuildingFootprintCutaway.subtract(mapped: [], from: cutawayRectangle(100_001, 0, 100_010, 10))
    }
}
