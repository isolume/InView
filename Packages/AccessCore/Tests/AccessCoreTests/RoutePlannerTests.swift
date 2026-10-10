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
private func crossing(of route: Route, at x: Float = 0) -> Float? {
    for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) where (a.x < x) != (b.x < x) {
        let t = (x - a.x) / (b.x - a.x)
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

@Test func routesToASelectedRoomThroughItsHallwayInsteadOfTheNearestElevator() throws {
    let start = SIMD2<Float>(-3, -1.4)
    let kitchen = AccessPoint(kind: .destination, name: "Kitchen", position: [3, 0, -1.4], source: .manual, confidence: 1)
    let desk = AccessPoint(kind: .destination, name: "Desk", position: [-2.8, 0, -1.3], source: .manual, confidence: 1)
    let elevator = point(.elevator, -3, -2)
    // Two rooms connect to a central hallway through doors at opposite ends.
    let map = room([
        wall(from: [-1, -3], to: [-1, 3]),
        wall(from: [1, -3], to: [1, 3]),
        Footprint(kind: .door, center: [-1, 1.7], size: [1.1, 0.15], yaw: .pi / 2),
        Footprint(kind: .door, center: [1, -1.7], size: [1.1, 0.15], yaw: .pi / 2),
    ], points: [desk, kitchen, elevator])
    let planner = RoutePlanner(map: map)

    let nearest = try #require(planner.nearestRoute(from: start))
    #expect(nearest.destination.id == elevator.id)
    let selected = try #require(planner.route(from: start, to: kitchen))
    #expect(selected.destination.id == kitchen.id)
    #expect(selected.destination.title == "Kitchen")
    #expect(selected.length > nearest.length + 5)
    #expect(!selected.isNarrow)
    #expect(abs(try #require(crossing(of: selected, at: -1)) - 1.7) < 0.45)
    #expect(abs(try #require(crossing(of: selected, at: 1)) + 1.7) < 0.45)

    let grid = planner.grids[selected.level]
    // Inspect every segment so an apparent cross-room route cannot cut through a divider.
    for (a, b) in zip(selected.waypoints, selected.waypoints.dropFirst()) {
        let steps = max(1, Int((simd_distance(a, b) / (grid.cellSize / 4)).rounded(.up)))
        for step in 0...steps {
            let position = a + (b - a) * (Float(step) / Float(steps))
            let index = try #require(grid.index(containing: position))
            #expect(!grid.isBlocked(index))
        }
    }

    let updated = try #require(planner.reroute(selected, from: [0, 0]))
    #expect(updated.destination.id == kitchen.id)
    #expect(updated.length < selected.length)
}

@Test func selectedDestinationRemainsUnreachableWhenRoomsHaveNoPassage() {
    let destination = AccessPoint(kind: .destination, name: "Kitchen", position: [3, 0, 0], source: .manual, confidence: 1)
    let planner = RoutePlanner(map: room([divider], points: [destination]))
    #expect(planner.route(from: [-3, 0], to: destination) == nil)
    #expect(planner.nearestRoute(from: [-3, 0]) == nil)
}
