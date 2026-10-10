import Foundation
import simd
import Testing
@testable import AccessCore

@Test func routesStraightAcrossAnOpenRoom() throws {
    let map = room(points: [point(.elevator, 2, 0)])
    let route = try #require(RoutePlanner(map: map).nearestRoute(from: [-2, 0]))
    #expect(!route.isNarrow)
    #expect(abs(route.length - 4) < 0.3)
    #expect(route.waypoints.count <= 3)
}

@Test func goesThroughAWideDoorway() throws {
    let map = room([divider, dividerDoor(at: 1.5, width: 0.9)], points: [point(.elevator, 2, -1)])
    let route = try #require(RoutePlanner(map: map).nearestRoute(from: [-2, -1]))
    #expect(route.length > 5)
    let z = try #require(crossing(of: route))
    #expect(abs(z - 1.5) < 0.45)
}

@Test func refusesDoorwaysNarrowerThanADA() {
    let map = room([divider, dividerDoor(at: 1.5, width: 0.7)], points: [point(.elevator, 2, -1)])
    #expect(RoutePlanner(map: map).nearestRoute(from: [-2, -1]) == nil)
}

@Test func avoidsStairs() throws {
    // Stairs fill the middle of the room except a 1 m gap along the top wall.
    let stairs = Footprint(kind: .stairs, center: [0, -0.5], size: [1, 5], yaw: 0)
    let map = room([stairs], points: [point(.ramp, 2, -2)])
    let route = try #require(RoutePlanner(map: map).nearestRoute(from: [-2, -2]))
    #expect(route.length > 6)
    let z = try #require(crossing(of: route))
    #expect(z > 2)
}

@Test func picksTheShortestRollNotTheClosestPoint() throws {
    // The elevator is 2.8 m away through the wall, but the only doorway is at the far end.
    let map = room([divider, dividerDoor(at: 2.2, width: 0.9)], points: [point(.elevator, 0.8, -2), point(.ramp, -2, 2)])
    let route = try #require(RoutePlanner(map: map).nearestRoute(from: [-2, -2]))
    #expect(route.destination.kind == .ramp)
}

@Test func reroutesFromANewPosition() throws {
    let planner = RoutePlanner(map: room(points: [point(.elevator, 3, 0)]))
    let first = try #require(planner.nearestRoute(from: [-3, 0]))
    let second = try #require(planner.reroute(first, from: [0, 1]))
    #expect(second.destination.id == first.destination.id)
    #expect(second.length < first.length)
}
