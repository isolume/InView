import Foundation
import simd
import Testing
@testable import AccessCore

@Test func skipsPointsReportedOutOfService() throws {
    let elevator = point(.elevator, -1, 0)
    let ramp = point(.ramp, 3, 0)
    let planner = RoutePlanner(map: room(points: [elevator, ramp]))
    let route = try #require(planner.nearestRoute(from: [-2, 0], conditions: RouteConditions(unavailable: [elevator.id])))
    #expect(route.destination.id == ramp.id)
}

@Test func reroutingDoesNotChangeTheDestinationWhenItGoesDown() throws {
    let elevator = point(.elevator, -1, 0)
    let ramp = point(.ramp, 3, 0)
    let planner = RoutePlanner(map: room(points: [elevator, ramp]))
    let first = try #require(planner.nearestRoute(from: [-3, 0]))
    #expect(first.destination.id == elevator.id)
    let conditions = RouteConditions(unavailable: [elevator.id])
    #expect(planner.reroute(first, from: [-2.5, 0], conditions: conditions) == nil)
    // An alternative remains available, but choosing it is a separate journey.
    #expect(planner.nearestRoute(from: [-2.5, 0], conditions: conditions)?.destination.id == ramp.id)
}

@Test func detoursAroundAnObstacleOnTheWay() throws {
    let planner = RoutePlanner(map: room(points: [point(.elevator, 3, 0)]))
    let clear = try #require(planner.nearestRoute(from: [-3, 0]))
    let blocked = try #require(planner.nearestRoute(from: [-3, 0], conditions: RouteConditions(obstacles: [[0, 0]])))
    #expect(blocked.length > clear.length + 0.1)
    #expect(Polyline.distance(from: [0, 0], to: blocked.waypoints) > RoutePlanner.obstacleRadius)
}

@Test func neverUsesASteepRampEvenWhenNothingElseIsReachable() throws {
    var steep = point(.ramp, -1, 0)
    steep.slopeDegrees = 7
    let gentle = point(.ramp, 3, 0)
    let planner = RoutePlanner(map: room(points: [steep, gentle]))
    let route = try #require(planner.nearestRoute(from: [-2, 0]))
    #expect(route.destination.id == gentle.id)
    #expect(planner.nearestRoute(from: [-2, 0], conditions: RouteConditions(unavailable: [gentle.id])) == nil)
    #expect(planner.route(from: [-2, 0], to: steep) == nil)
}

@Test func measuredSlopeRequirementRejectsUnknownAndInvalidRampInclines() throws {
    let unknown = point(.ramp, -1, 0)
    var invalid = point(.ramp, 0, 0)
    invalid.slopeDegrees = .nan
    var measured = point(.ramp, 3, 0)
    measured.slopeDegrees = 3
    let planner = RoutePlanner(map: room(points: [unknown, invalid, measured]))
    let conditions = RouteConditions(minimumClearance: 0.45, requiresMeasuredRampSlope: true)
    let route = try #require(planner.nearestRoute(from: [-2, 0], conditions: conditions))
    #expect(route.destination.id == measured.id)
    #expect(planner.route(from: [-2, 0], to: unknown, conditions: conditions) == nil)
    #expect(planner.route(from: [-2, 0], to: invalid, conditions: conditions) == nil)
}

@Test func minimumClearanceIsAHardFilterForSelectedAndNearestRoutes() throws {
    let elevator = point(.elevator, 3, 0)
    let planner = RoutePlanner(map: room([
        wall(from: [0, -3], to: [0, -0.4]),
        wall(from: [0, 0.4], to: [0, 3]),
    ], points: [elevator]))
    let cramped = try #require(planner.route(from: [-3, 0], to: elevator))
    #expect(cramped.clearance < 0.45)
    let conditions = RouteConditions(minimumClearance: 0.45)
    #expect(planner.route(from: [-3, 0], to: elevator, conditions: conditions) == nil)
    #expect(planner.nearestRoute(from: [-3, 0], conditions: conditions) == nil)
}

@Test func reroutingNeverNarrowsTheOriginalClearanceOrChangesTheDestination() throws {
    let selected = point(.elevator, 3, 0)
    let alternative = point(.elevator, -2, 1)
    let planner = RoutePlanner(map: room([
        wall(from: [0, -3], to: [0, -1]),
        wall(from: [0, 1], to: [0, 3]),
    ], points: [selected, alternative]))
    let original = try #require(planner.route(from: [-3, 0], to: selected,
                                            conditions: RouteConditions(minimumClearance: 0.45)))
    #expect(original.clearance == 0.45)
    let obstacle = RouteConditions(obstacles: [[0, 0]])
    // A cramped route and a different nearby destination both exist after the obstacle appears.
    #expect(try #require(planner.route(from: [-3, 0], to: selected, conditions: obstacle)).clearance < 0.45)
    #expect(planner.nearestRoute(from: [-3, 0], conditions: obstacle)?.destination.id == alternative.id)
    #expect(planner.reroute(original, from: [-3, 0], conditions: obstacle) == nil)
}

@Test func reroutingRespectsAStricterNewClearanceRequirement() throws {
    let selected = point(.elevator, 3, 0)
    let planner = RoutePlanner(map: room([
        wall(from: [0, -3], to: [0, -0.4]),
        wall(from: [0, 0.4], to: [0, 3]),
    ], points: [selected]))
    let original = try #require(planner.route(from: [-3, 0], to: selected))
    #expect(original.clearance < 0.45)
    #expect(planner.reroute(original, from: [-3, 0], conditions: RouteConditions(minimumClearance: 0.45)) == nil)
}

@Test func snapsElevatorPinsToTheFrontOfTheNearestDoor() {
    // A door in a wall along x at z = 0; its normal points along z.
    let door = Footprint(kind: .door, center: [2, 0], size: [1.0, 0.15], yaw: 0)
    let inFront = DoorSnap.snap(point(.elevator, 2.3, 0.9), to: [door], floorY: -1.3)
    #expect(simd_distance(inFront.floorPoint, [2, 0.6]) < 1e-4)
    #expect(inFront.position.y == -1.3)
    let behind = DoorSnap.snap(point(.elevator, 1.8, -0.4), to: [door], floorY: 0)
    #expect(simd_distance(behind.floorPoint, [2, -0.6]) < 1e-4)
}

@Test func leavesPinsAloneWhenNoDoorIsClose() {
    let door = Footprint(kind: .door, center: [5, 5], size: [1.0, 0.15], yaw: 0)
    let elevator = point(.elevator, 0, 0)
    #expect(DoorSnap.snap(elevator, to: [door], floorY: 0).floorPoint == elevator.floorPoint)
    let ramp = point(.ramp, 5, 5.5)
    #expect(DoorSnap.snap(ramp, to: [door], floorY: 0).floorPoint == ramp.floorPoint)
}

@Test func selectedDestinationsRespectOutagesAndDynamicObstacles() throws {
    let destination = AccessPoint(kind: .destination, name: "Kitchen", position: [3, 0, 0], source: .manual, confidence: 1)
    let planner = RoutePlanner(map: room(points: [destination]))
    let clear = try #require(planner.route(from: [-3, 0], to: destination))
    let blocked = try #require(planner.route(from: [-3, 0], to: destination, conditions: RouteConditions(obstacles: [[0, 0]])))
    #expect(blocked.length > clear.length + 0.1)
    #expect(Polyline.distance(from: [0, 0], to: blocked.waypoints) > RoutePlanner.obstacleRadius)
    #expect(planner.route(from: [-3, 0], to: destination, conditions: RouteConditions(unavailable: [destination.id])) == nil)
    #expect(planner.nearestRoute(from: [-3, 0]) == nil)
}
