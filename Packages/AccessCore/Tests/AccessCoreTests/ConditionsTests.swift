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

@Test func reroutesToAnotherPointWhenTheDestinationGoesDown() throws {
    let elevator = point(.elevator, -1, 0)
    let ramp = point(.ramp, 3, 0)
    let planner = RoutePlanner(map: room(points: [elevator, ramp]))
    let first = try #require(planner.nearestRoute(from: [-3, 0]))
    #expect(first.destination.id == elevator.id)
    let second = try #require(planner.reroute(first, from: [-2.5, 0], conditions: RouteConditions(unavailable: [elevator.id])))
    #expect(second.destination.id == ramp.id)
}

@Test func detoursAroundAnObstacleOnTheWay() throws {
    let planner = RoutePlanner(map: room(points: [point(.elevator, 3, 0)]))
    let clear = try #require(planner.nearestRoute(from: [-3, 0]))
    let blocked = try #require(planner.nearestRoute(from: [-3, 0], conditions: RouteConditions(obstacles: [[0, 0]])))
    #expect(blocked.length > clear.length + 0.1)
    #expect(Polyline.distance(from: [0, 0], to: blocked.waypoints) > RoutePlanner.obstacleRadius)
}

@Test func onlyUsesASteepRampWhenNothingElseIsReachable() throws {
    var steep = point(.ramp, -1, 0)
    steep.slopeDegrees = 7
    let gentle = point(.ramp, 3, 0)
    let planner = RoutePlanner(map: room(points: [steep, gentle]))
    let route = try #require(planner.nearestRoute(from: [-2, 0]))
    #expect(route.destination.id == gentle.id)
    let fallback = try #require(planner.nearestRoute(from: [-2, 0], conditions: RouteConditions(unavailable: [gentle.id])))
    #expect(fallback.destination.id == steep.id)
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
