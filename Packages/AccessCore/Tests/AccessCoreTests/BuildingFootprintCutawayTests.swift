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

private func regionContains(_ point: CutawayPoint, _ region: BuildingFootprintCutaway.Region) -> Bool {
    cutawayContains(point, region.exterior) && !region.holes.contains { cutawayContains(point, $0) }
}

private func regionSignedArea(_ ring: [CutawayPoint]) -> Double {
    ring.indices.reduce(0.0) { sum, i in
        let a = ring[i], b = ring[(i + 1) % ring.count]
        return sum + Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x)
    } / 2
}

/// Checks area, coverage and both sides of every output edge against the input geometry.
/// An internal triangulation wall has filled area on both sides, so it fails this check.
private func expectBoundaryRegions(
    _ regions: [BuildingFootprintCutaway.Region], bounds: [CutawayPoint], area: Double,
    inputRings: [[CutawayPoint]], contains expectedContains: (CutawayPoint) -> Bool
) {
    let actualArea = regions.reduce(0.0) { total, region in
        total + cutawayArea(region.exterior) - region.holes.reduce(0.0) { $0 + cutawayArea($1) }
    }
    #expect(abs(actualArea - area) < 0.0001)
    for region in regions {
        #expect(regionSignedArea(region.exterior) > 0)
        #expect(region.holes.allSatisfy { regionSignedArea($0) < 0 })
        for ring in [region.exterior] + region.holes {
            #expect(ring.count >= 3)
            #expect(ring.first != ring.last)
            #expect(Set(ring).count == ring.count)
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let direction = b - a
                let length = sqrt(direction.x * direction.x + direction.y * direction.y)
                let magnitude = max(abs(a.x), abs(a.y), abs(b.x), abs(b.y))
                let offset = max(0.001, magnitude * Float.ulpOfOne * 2)
                let normal = CutawayPoint(-direction.y, direction.x) / length * offset
                let midpoint = (a + b) / 2
                #expect(expectedContains(midpoint + normal))
                #expect(!expectedContains(midpoint - normal))
            }
        }
    }
    let minX = bounds.map(\.x).min()!, maxX = bounds.map(\.x).max()!
    let minY = bounds.map(\.y).min()!, maxY = bounds.map(\.y).max()!
    for x in 0..<31 {
        for y in 0..<29 {
            let point = CutawayPoint(minX + (maxX - minX) * (Float(x) + 0.37) / 31,
                                     minY + (maxY - minY) * (Float(y) + 0.61) / 29)
            if inputRings.contains(where: { cutawayNearBoundary(point, $0) }) { continue }
            let covered = regions.filter { regionContains(point, $0) }.count
            #expect((covered > 0) == expectedContains(point))
            #expect(covered <= 1)
        }
    }
}

private func expectSubtractedRegions(
    _ regions: [BuildingFootprintCutaway.Region], exterior: [CutawayPoint], holes: [[CutawayPoint]] = [],
    mapped: [[CutawayPoint]], area: Double
) {
    expectBoundaryRegions(regions, bounds: exterior, area: area, inputRings: [exterior] + holes + mapped) { point in
        cutawayContains(point, exterior)
            && !holes.contains { cutawayContains(point, $0) }
            && !mapped.contains { cutawayContains(point, $0) }
    }
}

private func expectUnitedRegions(
    _ regions: [BuildingFootprintCutaway.Region], polygons: [[CutawayPoint]], area: Double
) {
    expectBoundaryRegions(regions, bounds: polygons.flatMap { $0 }, area: area, inputRings: polygons) { point in
        polygons.contains { cutawayContains(point, $0) }
    }
}

@Test func cutawayRegionsReplaceFragmentWallsWithOneExteriorAndOneHole() throws {
    let outer = cutawayRectangle(0, 0, 10, 10), room = cutawayRectangle(2, 2, 8, 8)
    let pieces = try BuildingFootprintCutaway.subtract(mapped: [room], from: outer)
    #expect(pieces.count > 1)
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.exterior == outer)
    #expect(regions.first?.holes.count == 1)
    #expect(regions.first?.holes.first?.count == 4)
    expectSubtractedRegions(regions, exterior: outer, mapped: [room], area: 64)
}

@Test func cutawayRegionsJoinTriangulationEdgesAndTJunctions() throws {
    let outer: [CutawayPoint] = [[0, 0], [12, 0], [12, 4], [8, 4], [8, 12], [0, 12]]
    let diamond: [CutawayPoint] = [[4, 1], [7, 4], [4, 7], [1, 4]]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [diamond], from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.exterior == outer)
    #expect(regions.first?.holes.count == 1)
    #expect(regions.first?.holes.first?.count == 4)
    expectSubtractedRegions(regions, exterior: outer, mapped: [diamond], area: 94)
}

@Test func cutawayRegionsPreserveDisconnectedConcaveBuildingWings() throws {
    let outer: [CutawayPoint] = [[0, 0], [8, 0], [8, 3], [3, 3], [3, 8], [0, 8]]
    let room = cutawayRectangle(0, 0, 5, 5)
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer)
    #expect(regions.count == 2)
    #expect(regions.allSatisfy { $0.exterior.count == 4 && $0.holes.isEmpty })
    expectSubtractedRegions(regions, exterior: outer, mapped: [room], area: 18)
    let untouched = try BuildingFootprintCutaway.subtractRegions(mapped: [], from: outer)
    #expect(untouched == [.init(exterior: outer)])
}

@Test func cutawayRegionsCombineOverlappingMasksWithoutASeam() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let rooms = [cutawayRectangle(1, 1, 6, 6), cutawayRectangle(4, 4, 9, 9)]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: rooms, from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.holes.count == 1)
    #expect(regions.first?.holes.first?.count == 8)
    expectSubtractedRegions(regions, exterior: outer, mapped: rooms, area: 54)
    #expect(try BuildingFootprintCutaway.subtractRegions(mapped: rooms.reversed(), from: outer) == regions)
}

@Test func cutawayRegionsPreserveConcaveCourtyardsAndMergeAConnectingCut() throws {
    let outer = cutawayRectangle(0, 0, 12, 12)
    let courtyard: [CutawayPoint] = [[2, 2], [7, 2], [7, 4], [4, 4], [4, 7], [2, 7]]
    let room = cutawayRectangle(3, 5, 6, 9)
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer, holes: [courtyard])
    #expect(regions.count == 1)
    #expect(regions.first?.holes.count == 1)
    expectSubtractedRegions(regions, exterior: outer, holes: [courtyard], mapped: [room], area: 118)
}

@Test func cutawayRegionsOpenMasksTouchingTheExteriorIntoANotch() throws {
    let outer = cutawayRectangle(0, 0, 10, 10), room = cutawayRectangle(-2, 3, 4, 7)
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.holes.isEmpty == true)
    #expect(regions.first?.exterior.count == 8)
    expectSubtractedRegions(regions, exterior: outer, mapped: [room], area: 84)
}

@Test func cutawayRegionsClipRotatedRoomsIntoFourDisconnectedCorners() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let room: [CutawayPoint] = [[5, -1], [11, 5], [5, 11], [-1, 5]]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer)
    #expect(regions.count == 4)
    #expect(regions.allSatisfy { $0.exterior.count == 3 && $0.holes.isEmpty })
    expectSubtractedRegions(regions, exterior: outer, mapped: [room], area: 32)
}

@Test func cutawayRegionsGroupHolesWithTheCorrectDisconnectedWing() throws {
    let outer = cutawayRectangle(0, 0, 12, 10)
    let courtyard = cutawayRectangle(8, 2, 10, 4)
    let rooms = [cutawayRectangle(5, -1, 7, 11), cutawayRectangle(1, 2, 3, 4)]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: rooms, from: outer, holes: [courtyard])
    #expect(regions.count == 2)
    #expect(regions.allSatisfy { $0.holes.count == 1 })
    expectSubtractedRegions(regions, exterior: outer, holes: [courtyard], mapped: rooms, area: 92)
}

@Test func cutawayRegionsRetainAnUnmappedIslandInsideAnEnclosedMappedRing() throws {
    let outer = cutawayRectangle(0, 0, 12, 12)
    let rooms = [cutawayRectangle(2, 2, 10, 4), cutawayRectangle(2, 8, 10, 10),
                 cutawayRectangle(2, 4, 4, 8), cutawayRectangle(8, 4, 10, 8)]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: rooms, from: outer)
    #expect(regions.count == 2)
    #expect(regions.map { $0.holes.count }.sorted() == [0, 1])
    expectSubtractedRegions(regions, exterior: outer, mapped: rooms, area: 96)
}

@Test func cutawayRegionsAcceptConcaveMeasuredFloorsAndPreserveTheirUnmappedNotch() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let room: [CutawayPoint] = [[1, 1], [7, 1], [7, 3], [3, 3], [3, 7], [1, 7]]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.holes.first?.count == 6)
    expectSubtractedRegions(regions, exterior: outer, mapped: [room], area: 80)
}

@Test func cutawayRegionsNormalizeClosedAndReversedRingsDeterministically() throws {
    let outer = cutawayRectangle(0, 0, 12, 12), courtyard = cutawayRectangle(4, 4, 8, 8)
    let room = cutawayRectangle(0, 0, 6, 6)
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [room], from: outer, holes: [courtyard])
    func reversedClosed(_ ring: [CutawayPoint]) -> [CutawayPoint] { Array(ring.reversed()) + [ring.last!] }
    #expect(try BuildingFootprintCutaway.subtractRegions(mapped: [reversedClosed(room)],
        from: reversedClosed(outer), holes: [reversedClosed(courtyard)]) == regions)
    expectSubtractedRegions(regions, exterior: outer, holes: [courtyard], mapped: [room], area: 96)
}

@Test func cutawayFloorUnionRemovesOverlappingSectionEdges() throws {
    let floors = [cutawayRectangle(0, 0, 6, 6), cutawayRectangle(3, 0, 9, 6)]
    let regions = try BuildingFootprintCutaway.unionRegions(floors)
    #expect(regions == [.init(exterior: cutawayRectangle(0, 0, 9, 6))])
    expectUnitedRegions(regions, polygons: floors, area: 54)
    #expect(try BuildingFootprintCutaway.unionRegions(floors.reversed()) == regions)
    #expect(try BuildingFootprintCutaway.unionRegions(floors + floors) == regions)
}

@Test func cutawayFloorUnionPreservesConcaveFloorsAndDisconnectedSections() throws {
    let concave: [CutawayPoint] = [[0, 0], [6, 0], [6, 2], [2, 2], [2, 6], [0, 6]]
    let floors = [concave, cutawayRectangle(0, 4, 4, 8), cutawayRectangle(8, 0, 10, 2)]
    let regions = try BuildingFootprintCutaway.unionRegions(floors)
    #expect(regions.count == 2)
    #expect(regions.allSatisfy { $0.holes.isEmpty })
    expectUnitedRegions(regions, polygons: floors, area: 36)
}

@Test func cutawayFloorUnionPreservesEnclosedUnmappedGapsAsHoles() throws {
    let floors = [cutawayRectangle(2, 2, 10, 4), cutawayRectangle(2, 8, 10, 10),
                  cutawayRectangle(2, 4, 4, 8), cutawayRectangle(8, 4, 10, 8)]
    let regions = try BuildingFootprintCutaway.unionRegions(floors)
    #expect(regions.count == 1)
    #expect(regions.first?.exterior == cutawayRectangle(2, 2, 10, 10))
    #expect(regions.first?.holes.count == 1)
    expectUnitedRegions(regions, polygons: floors, area: 48)
}

@Test func cutawayFloorUnionKeepsPointTouchingFloorsAsSeparateRegions() throws {
    let floors = [cutawayRectangle(0, 0, 2, 2), cutawayRectangle(2, 2, 4, 4)]
    let regions = try BuildingFootprintCutaway.unionRegions(floors)
    #expect(regions.count == 2)
    expectUnitedRegions(regions, polygons: floors, area: 8)
}

@Test func cutawayRegionOperationsKeepEmptyAndInvalidInputsBounded() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    #expect(try BuildingFootprintCutaway.unionRegions([]).isEmpty)
    #expect(try BuildingFootprintCutaway.subtractRegions(mapped: [outer], from: outer).isEmpty)
    #expect(throws: BuildingFootprintCutawayError.invalidPolygon) {
        try BuildingFootprintCutaway.unionRegions([[[0, 0], [4, 4], [0, 4], [4, 0]]])
    }
    #expect(throws: BuildingFootprintCutawayError.geometryTooComplex) {
        try BuildingFootprintCutaway.unionRegions(Array(repeating: outer, count: 129))
    }
    #expect(throws: BuildingFootprintCutawayError.geometryTooComplex) {
        try BuildingFootprintCutaway.subtractRegions(mapped: Array(repeating: outer, count: 129), from: outer)
    }
}

@Test func cutawayRegionsKeepPointTouchingCutoutsAsSimpleHoles() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let rooms = [cutawayRectangle(1, 1, 4, 4), cutawayRectangle(4, 4, 7, 7)]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: rooms, from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.holes.count == 2)
    expectSubtractedRegions(regions, exterior: outer, mapped: rooms, area: 82)
}

@Test func cutawayRegionsKeepACutoutTangentToTheExteriorAsASimpleRing() throws {
    let outer = cutawayRectangle(0, 0, 10, 10)
    let diamond: [CutawayPoint] = [[0, 4], [2, 2], [4, 4], [2, 6]]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: [diamond], from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.exterior == outer)
    #expect(regions.first?.holes.count == 1)
    expectSubtractedRegions(regions, exterior: outer, mapped: [diamond], area: 92)
}

@Test func cutawayFloorUnionCombinesManyOverlappingSectionsWithinTheWorkBudget() throws {
    let floors = (0..<8).flatMap { x in
        (0..<8).map { y in cutawayRectangle(Float(x), Float(y), Float(x) + 1.5, Float(y) + 1.5) }
    }
    let regions = try BuildingFootprintCutaway.unionRegions(floors)
    #expect(regions == [.init(exterior: cutawayRectangle(0, 0, 8.5, 8.5))])
    expectUnitedRegions(regions, polygons: floors, area: 72.25)
}

@Test func cutawayRegionsPreserveTranslatedMeasuredEdgesAtLargeCoordinates() throws {
    let origin = CutawayPoint(80_000, 70_000)
    let outer = cutawayRectangle(0, 0, 12, 12).map { $0 + origin }
    let diamond: [CutawayPoint] = [[4, 1], [7, 4], [4, 7], [1, 4]]
    let rooms = [diamond.map { $0 + origin }]
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: rooms, from: outer)
    #expect(regions.count == 1)
    #expect(regions.first?.exterior == outer)
    #expect(regions.first?.holes.first?.count == 4)
    expectSubtractedRegions(regions, exterior: outer, mapped: rooms, area: 126)
}

@Test func cutawayRegionsPreserveRotatedOverlapsAndStableOrdering() throws {
    let outer: [CutawayPoint] = [[0, 0], [18, 0], [18, 10], [12, 10], [12, 18], [0, 18]]
    let rooms = (0..<6).map { index -> [CutawayPoint] in
        let angle = Float(index) * 0.13 + 0.21
        let center = CutawayPoint(Float(index % 3) * 3 + 3, Float(index / 3) * 4 + 4)
        return cutawayRectangle(-2, -1, 2, 1).map { point in
            center + CutawayPoint(point.x * cos(angle) - point.y * sin(angle),
                                  point.x * sin(angle) + point.y * cos(angle))
        }
    }
    let pieces = try BuildingFootprintCutaway.subtract(mapped: rooms, from: outer)
    let regions = try BuildingFootprintCutaway.subtractRegions(mapped: rooms, from: outer)
    expectSubtractedRegions(regions, exterior: outer, mapped: rooms,
                            area: pieces.reduce(0.0) { $0 + cutawayArea($1) })
    #expect(try BuildingFootprintCutaway.subtractRegions(mapped: rooms.reversed(), from: outer) == regions)
    let united = try BuildingFootprintCutaway.unionRegions(rooms)
    #expect(try BuildingFootprintCutaway.unionRegions(rooms.reversed()) == united)
    expectUnitedRegions(united, polygons: rooms,
                        area: cutawayArea(outer) - pieces.reduce(0.0) { $0 + cutawayArea($1) })
}
