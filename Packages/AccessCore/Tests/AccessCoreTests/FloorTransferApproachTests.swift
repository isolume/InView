import simd
import Testing
@testable import AccessCore

@Test func floorTransferKeepsStairsOutOfStepFreeDirections() throws {
    let stairs = Footprint(kind: .stairs, center: [0, 0], size: [1, 2], yaw: 0)
    let map = room([stairs], points: [point(.elevator, 3, 0)])
    let candidates = FloorTransferApproach.candidates(in: map, preference: .fastest)
    #expect(candidates.filter { $0.kind == .stairs }.count == 2)
    #expect(FloorTransferApproach.candidates(in: map, preference: .stepFree).allSatisfy { $0.kind == .elevator })
    let route = try #require(FloorTransferApproach.nearestRoute(from: [-2, -2],
        planner: RoutePlanner(map: map), candidates: candidates, conditions: RoutePreference.stepFree.conditions()))
    #expect(route.destination.kind == .elevator)
}

@Test func floorTransferFastestCanApproachStairsWithoutWalkingThroughThem() throws {
    let stairs = Footprint(kind: .stairs, center: [0, 0], size: [1, 2], yaw: 0)
    let map = room([stairs], points: [point(.elevator, 3, 1)])
    let candidates = FloorTransferApproach.candidates(in: map, preference: .fastest)
    let planner = RoutePlanner(map: map)
    let route = try #require(FloorTransferApproach.nearestRoute(from: [0, -2], planner: planner,
        candidates: candidates, conditions: RoutePreference.fastest.conditions()))
    #expect(candidates.first { $0.destination.id == route.destination.id }?.kind == .stairs)
    #expect(route.waypoints.allSatisfy { !Polygon.contains($0, in: stairs.corners) })
    #expect(route.waypoints.last!.y < -1)
}

@Test func floorTransferChoosesReachableElevatorByWalkingDistanceAndRespectsClosures() throws {
    let near = point(.elevator, 0.8, -2)
    let far = point(.elevator, -2, 2)
    let map = room([divider, dividerDoor(at: 2.2, width: 0.9)], points: [near, far])
    let candidates = FloorTransferApproach.candidates(in: map, preference: .stepFree)
    let planner = RoutePlanner(map: map)
    let route = try #require(FloorTransferApproach.nearestRoute(from: [-2, -2], planner: planner,
        candidates: candidates, conditions: RoutePreference.stepFree.conditions()))
    #expect(route.destination.id == far.id)
    var closed = RoutePreference.stepFree.conditions()
    closed.unavailable = [near.id, far.id]
    #expect(FloorTransferApproach.nearestRoute(from: [-2, -2], planner: planner,
        candidates: candidates, conditions: closed) == nil)
}
