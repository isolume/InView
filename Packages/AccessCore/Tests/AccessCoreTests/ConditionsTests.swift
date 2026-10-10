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
