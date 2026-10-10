import Foundation
import simd
import Testing
@testable import AccessCore

@Test func announcesTurnsOnTheCorrectSide() throws {
    // Heading forward (-z), then right (+x), then forward again (-z): a right turn then a left turn.
    let waypoints: [SIMD2<Float>] = [[0, 0], [0, -2], [2, -2], [2, -4]]
    let route = Route(destination: point(.elevator, 2, -4), waypoints: waypoints, length: 6, clearance: 0.45, level: 0, goalIndex: 0)
    let maneuver = try #require(route.nextManeuver)
    #expect(maneuver.turn == .right)
    #expect(abs(maneuver.distance - 2) < 1e-4)

    let rest = Route(destination: route.destination, waypoints: Array(waypoints.dropFirst()), length: 4, clearance: 0.45, level: 0, goalIndex: 0)
    #expect(rest.nextManeuver?.turn == .left)
}

@Test func straightRoutesHaveNoTurns() {
    let route = Route(destination: point(.elevator, 0, -4), waypoints: [[0, 0], [0.05, -2], [0, -4]], length: 4, clearance: 0.45, level: 0, goalIndex: 0)
    #expect(route.nextManeuver == nil)
}
