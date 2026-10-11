import simd
import Testing
@testable import AccessCore

private func measuredRectangle(_ lower: SIMD2<Float>, _ upper: SIMD2<Float>, elevation: Float = 0) -> Footprint {
    Footprint(floor: [lower, [upper.x, lower.y], upper, [lower.x, upper.y]], bottom: elevation)
}

@Test func concaveFloorRoutesAroundTheUnobservedBalconyVoid() throws {
    let floor = Footprint(floor: [[0, 0], [6, 0], [6, 2], [2, 2], [2, 6], [0, 6]], bottom: 0)
    let destination = point(.elevator, 5, 1)
    let map = VenueMap(floorY: 0, footprints: [floor], points: [destination])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(grid.isBlocked(try #require(grid.index(containing: [4, 4]))))
    #expect(!grid.isBlocked(try #require(grid.index(containing: [1, 4]))))
    #expect(!grid.lineOfSight([1, 5], [5, 1]))
    let route = try #require(RoutePlanner(map: map).route(from: [1, 5], to: destination))
    #expect(route.waypoints.count >= 3)
    for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) { #expect(grid.lineOfSight(a, b)) }
}

@Test func anElevatorMarkerBeyondTheObservedFloorDoesNotCreateARoute() throws {
    let destination = point(.elevator, 9, 0)
    let map = VenueMap(floorY: 0, footprints: [measuredRectangle([-2, -2], [2, 2])], points: [destination])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(grid.isBlocked(try #require(grid.index(containing: destination.floorPoint))))
    #expect(grid.isBlocked(try #require(grid.index(containing: [5, 0]))))
    #expect(RoutePlanner(map: map).route(from: .zero, to: destination) == nil)
}

@Test func disconnectedMeasuredFloorsCannotRouteAcrossUnknownSpace() throws {
    let destination = point(.elevator, 3, 0)
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([-4, -2], [-1, 2]), measuredRectangle([1, -2], [4, 2]),
    ], points: [destination])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(grid.isBlocked(try #require(grid.index(containing: .zero))))
    #expect(!grid.isBlocked(try #require(grid.index(containing: destination.floorPoint))))
    #expect(RoutePlanner(map: map).route(from: [-3, 0], to: destination) == nil)
}

@Test func overlappingFloorSectionsFormContinuousCoverageWithoutFillingTheirGap() throws {
    let destination = point(.elevator, 5, 1)
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([0, 0], [4, 2]), measuredRectangle([2, 0], [6, 2]),
        measuredRectangle([0, 1], [2, 6]),
    ], points: [destination])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(!grid.isBlocked(try #require(grid.index(containing: [3, 1]))))
    #expect(grid.isBlocked(try #require(grid.index(containing: [3, 3]))))
    #expect(RoutePlanner(map: map).route(from: [1, 5], to: destination) != nil)
}

@Test func doorwayReopeningCannotCreateFloorPastTheObservedEdge() throws {
    let doorway = Footprint(kind: .door, center: [0, 2], size: [1.2, 0.15], yaw: 0)
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([-2, -2], [2, 2]), wall(from: [-2, 2], to: [2, 2]), doorway,
    ], points: [])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    // This lies in the reopened doorway lane but outside all measured floor polygons.
    #expect(grid.isBlocked(try #require(grid.index(containing: [0, 2.3]))))
    #expect(!grid.isBlocked(try #require(grid.index(containing: [0, 1.8]))))
}

@Test func floorsAtAnotherLevelDoNotExtendTheActiveRoutingFloor() throws {
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([-3, -2], [0, 2], elevation: 0.3),
        measuredRectangle([-1, -2], [3, 2], elevation: 3),
    ], points: [])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(!grid.isBlocked(try #require(grid.index(containing: [-2, 0]))))
    #expect(grid.isBlocked(try #require(grid.index(containing: [1, 0]))))
    let otherLevelOnly = OccupancyGrid(map: VenueMap(floorY: 0, footprints: [map.footprints[1]], points: []), clearance: 0.45)
    #expect((0..<(otherLevelOnly.width * otherLevelOnly.height)).allSatisfy(otherLevelOnly.isBlocked))
}

@Test func aMeasuredLowRailingStillBlocksCrossingTheBalcony() throws {
    let railing = Footprint(kind: .wall, center: [0, 0], size: [6, 0.1], yaw: 0, bottom: 0.4, height: 0.6)
    let destination = point(.elevator, 0, 2)
    let map = VenueMap(floorY: 0, footprints: [measuredRectangle([-3, -4], [3, 4]), railing], points: [destination])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(grid.isBlocked(try #require(grid.index(containing: [0, 0]))))
    #expect(RoutePlanner(map: map).route(from: [0, -2], to: destination) == nil)
}

@Test func invalidFloorOutlinesNeverOpenTheirBoundingRectangle() {
    let invalid: [[SIMD2<Float>]] = [
        [[0, 0], [4, 0]],
        [[0, 0], [2, 0], [4, 0]],
        [[0, 0], [4, 0], [Float.nan, 4]],
        [[0, 0], [4, 4], [0, 4], [3, 0]], // Self-crossing with nonzero signed area.
    ]
    for polygon in invalid {
        let floor = Footprint(kind: .floor, center: [2, 2], size: [4, 4], yaw: 0, bottom: 0, polygon: polygon)
        let grid = OccupancyGrid(map: VenueMap(floorY: 0, footprints: [floor], points: []), clearance: 0.45)
        #expect((0..<(grid.width * grid.height)).allSatisfy(grid.isBlocked))
    }
    let unmeasured = Footprint(kind: .floor, center: .zero, size: [4, 4], yaw: 0)
    let grid = OccupancyGrid(map: VenueMap(floorY: 0, footprints: [unmeasured], points: []), clearance: 0.45)
    #expect((0..<(grid.width * grid.height)).allSatisfy(grid.isBlocked))
}

@Test func floorCoverageAcceptsReversedClosedOutlinesWithoutGrowingThem() throws {
    let outline: [SIMD2<Float>] = [[0, 0], [0, 4], [4, 4], [4, 0], [0, 0]]
    let map = VenueMap(floorY: 0, footprints: [Footprint(floor: outline, bottom: 0)], points: [])
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(!grid.isBlocked(try #require(grid.index(containing: [2, 2]))))
    #expect(grid.isBlocked(try #require(grid.index(containing: [-0.2, 2]))))
}

@Test func aLegacyMapWithoutFloorsRetainsItsRoutingBehavior() throws {
    let destination = point(.elevator, 2, 0)
    let map = room(points: [destination])
    #expect(!map.footprints.contains { $0.kind == .floor })
    let grid = OccupancyGrid(map: map, clearance: 0.45)
    #expect(!grid.isBlocked(try #require(grid.index(containing: .zero))))
    #expect(RoutePlanner(map: map).route(from: [-2, 0], to: destination) != nil)
}

@Test func navigationMayCrossUnmappedSpaceAndReportsHowFar() throws {
    // The elevator lobby wasn't recorded as floor, like a hallway walked past while scanning.
    let destination = point(.elevator, 3, 0)
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([-4, -2], [-1, 2]), measuredRectangle([1, -2], [4, 2]),
    ], points: [destination])
    let planner = RoutePlanner(map: map)
    var conditions = RoutePreference.stepFree.conditions()
    #expect(planner.route(from: [-3, 0], to: destination, conditions: conditions) == nil)
    conditions.allowsUnmappedSpace = true
    let route = try #require(planner.route(from: [-3, 0], to: destination, conditions: conditions))
    #expect(abs(route.unmappedLength - 2) < 0.3)
    #expect(route.length > 5 && route.length < 7)
    let far = point(.elevator, 9, 0)
    let lobby = VenueMap(floorY: 0, footprints: [measuredRectangle([-2, -2], [2, 2])], points: [far])
    let toLobby = try #require(RoutePlanner(map: lobby).route(from: .zero, to: far, conditions: conditions))
    #expect(toLobby.unmappedLength > 6)
}

@Test func unmappedSpaceIsOnlyUsedWhenMeasuredFloorHasNoWay() throws {
    // A measured detour exists, so the route keeps to it despite the shorter unmapped gap.
    let destination = point(.elevator, 3, 0)
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([-4, -2], [-1, 2]), measuredRectangle([1, -2], [4, 2]), measuredRectangle([-4, 2], [4, 5]),
    ], points: [destination])
    var conditions = RoutePreference.stepFree.conditions()
    conditions.allowsUnmappedSpace = true
    let route = try #require(RoutePlanner(map: map).route(from: [-3, 0], to: destination, conditions: conditions))
    #expect(route.unmappedLength == 0)
}

@Test func unmappedSpaceStillRespectsWalls() throws {
    let destination = point(.elevator, 3, 0)
    let wall = Footprint(kind: .wall, center: [0, 0], size: [0.2, 20], yaw: 0)
    let map = VenueMap(floorY: 0, footprints: [
        measuredRectangle([-4, -2], [-1, 2]), measuredRectangle([1, -2], [4, 2]), wall,
    ], points: [destination])
    var conditions = RoutePreference.stepFree.conditions()
    conditions.allowsUnmappedSpace = true
    // The only way is around the end of the wall, never through it.
    let route = try #require(RoutePlanner(map: map).route(from: [-3, 0], to: destination, conditions: conditions))
    for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) where (a.x < 0) != (b.x < 0) {
        let crossing = a.y + (b.y - a.y) * (-a.x / (b.x - a.x))
        #expect(abs(crossing) >= 10)
    }
}
