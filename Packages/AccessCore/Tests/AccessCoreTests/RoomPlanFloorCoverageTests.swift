import simd
import Testing
@testable import AccessCore

private func coverageFloor(_ x: ClosedRange<Float>, _ z: ClosedRange<Float>, elevation: Float = -1.3) -> Footprint {
    Footprint(floor: [[x.lowerBound, z.lowerBound], [x.upperBound, z.lowerBound],
                      [x.upperBound, z.upperBound], [x.lowerBound, z.upperBound]], bottom: elevation)
}

private func coverageContains(_ floors: [Footprint], _ point: SIMD2<Float>) -> Bool {
    floors.contains { floor in
        let polygon = floor.corners
        var inside = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
}

private func coverageArea(_ floors: [Footprint]) -> Float {
    floors.reduce(0) { $0 + abs(Polygon.signedArea($1.corners)) }
}

@Test func roomPlanMissingFloorRetainsAllMeasuredLargeRoomPatchesWithoutBridgingGaps() {
    let observations = [coverageFloor(0...6, 0...9), coverageFloor(7...15, 0...9)]
    let floors = RoomPlanFloorCoverage.additions(observed: observations, nativeFloors: [], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 126) < 0.001)
    #expect(coverageContains(floors, [3, 4]))
    #expect(coverageContains(floors, [11, 4]))
    #expect(!coverageContains(floors, [6.5, 4]))
}

@Test func roomPlanMissingFloorKeepsConcaveMeasuredOutline() {
    let outline: [SIMD2<Float>] = [[0, 0], [6, 0], [6, 2], [2, 2], [2, 6], [0, 6]]
    let floors = RoomPlanFloorCoverage.additions(observed: [Footprint(floor: outline, bottom: -1.3)],
                                               nativeFloors: [], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 20) < 0.001)
    #expect(coverageContains(floors, [1, 5]))
    #expect(coverageContains(floors, [5, 1]))
    #expect(!coverageContains(floors, [5, 5]))
}

@Test func roomPlanMissingFloorSubtractsOverlapsWithoutDoubleCounting() {
    let observed = [coverageFloor(0...4, 0...4), coverageFloor(2...6, 0...4)]
    let floors = RoomPlanFloorCoverage.additions(observed: observed, nativeFloors: [], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 24) < 0.001)
    #expect(coverageContains(floors, [5, 2]))
    #expect(coverageContains(floors, [3, 2]))
}

@Test func roomPlanNativeFloorAcceptsOnlyConnectedMeasuredExtensions() {
    let native = coverageFloor(0...4, 0...4)
    let extending = coverageFloor(3...6, 0...4)
    let separate = coverageFloor(8...10, 0...4)
    let floors = RoomPlanFloorCoverage.additions(observed: [extending, separate], nativeFloors: [native], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 8) < 0.001)
    #expect(coverageContains(floors, [5, 2]))
    #expect(!coverageContains(floors, [9, 2]))
    #expect(!coverageContains(floors, [2, 2]))
}

@Test func roomPlanMeasuredCorridorExtensionsDoNotDependOnObservationOrder() {
    let native = coverageFloor(0...4, 0...4)
    let near = coverageFloor(3...6, 0...4)
    let middle = coverageFloor(5...8, 0...4)
    let far = coverageFloor(7...10, 0...4)
    let orders = [[near, middle, far], [near, far, middle], [middle, near, far],
                  [middle, far, near], [far, near, middle], [far, middle, near]]
    for observations in orders {
        let floors = RoomPlanFloorCoverage.additions(observed: observations, nativeFloors: [native], floorY: -1.3)
        #expect(abs(coverageArea(floors) - 24) < 0.001)
        for x: Float in [5, 7, 9] { #expect(coverageContains(floors, [x, 2])) }
        #expect(!coverageContains(floors, [2, 2]))
    }
}

@Test func roomPlanMeasuredCorridorRecoveryStopsAtGapsAndRejectsOtherFloors() {
    let native = coverageFloor(0...4, 0...4)
    let near = coverageFloor(3...6, 0...4)
    let far = coverageFloor(5...8, 0...4)
    let disconnected = coverageFloor(9...12, 0...4)
    let upstairsBridge = coverageFloor(7...10, 0...4, elevation: 1.9)
    let floors = RoomPlanFloorCoverage.additions(observed: [disconnected, upstairsBridge, far, near],
                                               nativeFloors: [native], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 16) < 0.001)
    #expect(coverageContains(floors, [7, 2]))
    #expect(!coverageContains(floors, [8.5, 2]))
    #expect(!coverageContains(floors, [10, 2]))
    #expect(floors.allSatisfy { $0.bottom == -1.3 })
}

@Test func roomPlanMeasuredCorridorRecoveryHandlesReverseChainWithoutDuplicatingCoverage() {
    let native = coverageFloor(0...2, 0...2)
    let chain = (1...24).reversed().map { index in
        coverageFloor(Float(index)...Float(index + 2), 0...2)
    }
    let floors = RoomPlanFloorCoverage.additions(observed: chain + chain, nativeFloors: [native], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 48) < 0.001)
    #expect(coverageContains(floors, [25, 1]))
    #expect(!coverageContains(floors, [1, 1]))
}

@Test func roomPlanFloorSupplementsPreserveSubtractionHoles() {
    let nativeIsland = coverageFloor(2...4, 2...4)
    let surroundingMeasured = coverageFloor(0...6, 0...6)
    let floors = RoomPlanFloorCoverage.additions(observed: [surroundingMeasured],
                                               nativeFloors: [nativeIsland], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 32) < 0.001)
    #expect(coverageContains(floors, [1, 3]))
    #expect(coverageContains(floors, [5, 3]))
    #expect(!coverageContains(floors, [3, 3]))
}

@Test func roomPlanMissingFloorNeverPromotesBarriersOrAnotherStory() {
    let actual = coverageFloor(0...4, 0...4)
    let downstairs = coverageFloor(0...8, 0...8, elevation: -4.3)
    var barrier = coverageFloor(8...10, 0...4)
    barrier.kind = .wall
    var obstacle = coverageFloor(10...12, 0...4)
    obstacle.kind = .obstacle
    let floors = RoomPlanFloorCoverage.additions(observed: [downstairs, barrier, obstacle, actual],
                                               nativeFloors: [], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 16) < 0.001)
    #expect(floors.allSatisfy { $0.kind == .floor && $0.bottom == -1.3 })
}

@Test func roomPlanFloorOnAnotherStoryDoesNotBlockMeasuredFallback() {
    let actual = coverageFloor(0...4, 0...4)
    let upstairs = coverageFloor(8...10, 0...4, elevation: 1.9)
    let floors = RoomPlanFloorCoverage.additions(observed: [actual], nativeFloors: [upstairs], floorY: -1.3)
    #expect(abs(coverageArea(floors) - 16) < 0.001)
}

@Test func roomPlanMissingFloorDoesNotReplaceInvalidMeasurementsWithABoundingBox() {
    var invalid = coverageFloor(0...4, 0...4)
    invalid.polygon = [[0, 0], [4, 4], [0, 4], [4, 0]]
    let floors = RoomPlanFloorCoverage.additions(observed: [invalid], nativeFloors: [], floorY: -1.3)
    #expect(floors.isEmpty)
}
