import Foundation
import simd
import Testing
@testable import AccessCore

// All maps are an 8 x 6 m room spanning (-4, -3) to (4, 3), optionally split by a wall at x = 0.

private func wall(from a: SIMD2<Float>, to b: SIMD2<Float>) -> Footprint {
    let direction = b - a
    return Footprint(kind: .wall, center: (a + b) / 2, size: SIMD2(simd_length(direction), 0.15), yaw: atan2(direction.y, direction.x))
}

private func dividerDoor(at z: Float, width: Float) -> Footprint {
    Footprint(kind: .door, center: SIMD2(0, z), size: SIMD2(width, 0.15), yaw: .pi / 2)
}

private func point(_ kind: AccessPoint.Kind, _ x: Float, _ z: Float) -> AccessPoint {
    AccessPoint(kind: kind, position: SIMD3(x, 0, z), source: .manual, confidence: 1)
}

private func room(_ extra: [Footprint] = [], points: [AccessPoint]) -> VenueMap {
    let outer = [
        wall(from: [-4, -3], to: [4, -3]),
        wall(from: [4, -3], to: [4, 3]),
        wall(from: [4, 3], to: [-4, 3]),
        wall(from: [-4, 3], to: [-4, -3]),
    ]
    return VenueMap(floorY: 0, footprints: outer + extra, points: points)
}

private let divider = wall(from: [0, -3], to: [0, 3])

/// Where the route crosses x = 0, as a z coordinate.
private func crossing(of route: Route) -> Float? {
    for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) where (a.x < 0) != (b.x < 0) {
        let t = -a.x / (b.x - a.x)
        return a.y + (b.y - a.y) * t
    }
    return nil
}

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
