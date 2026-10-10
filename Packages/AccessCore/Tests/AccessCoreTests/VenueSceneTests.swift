import Foundation
import simd
import Testing
@testable import AccessCore

private func height(of pose: [Float]) -> Float { pose[13] }

@Test func venueSceneShowsEveryMapAsA3DRoom() throws {
    let outline: [SIMD2<Float>] = [[0, 0], [6, 0], [6, 3], [3, 3], [3, 6], [0, 6]]
    let map = VenueMap(floorY: -1.4, footprints: [
        Footprint(floor: outline, bottom: -1.4),
        Footprint(kind: .wall, center: [3, 0], size: [6, 0.1], yaw: 0, bottom: -1.4, height: 2.6),
        Footprint(kind: .door, center: [2, 0], size: [0.9, 0.15], yaw: 0, bottom: -1.4, height: 2.1),
        Footprint(kind: .obstacle, center: [1, 1], size: [0.5, 0.5], yaw: 0.3, furniture: .chair, bottom: -1.4, height: 0.9),
        Footprint(kind: .stairs, center: [5, 1], size: [1, 2], yaw: 0, bottom: -1.4, height: 0.7),
    ], points: [])

    let scene = try #require(VenueScene.make(from: map))

    #expect(scene.surfaces.map(\.kind).sorted() == ["door", "floor", "wall"])
    let floor = try #require(scene.surfaces.first { $0.kind == "floor" })
    #expect(floor.outline?.count == outline.count)
    #expect(scene.objects.map(\.sourceCategory).sorted() == ["chair", "stairs"])
    #expect(scene.objects.first { $0.sourceCategory == "chair" }?.modelKey == "chair_v2")
    try scene.validate()
}

@Test func venueSceneSetsRaisedRoomsOnTheMapFloor() throws {
    // RoomPlan measured the second room 0.67 m higher; routing treats it as the same floor.
    let low: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 4], [0, 4]]
    let high: [SIMD2<Float>] = [[4, 0], [8, 0], [8, 4], [4, 4]]
    let map = VenueMap(floorY: -1.4, footprints: [
        Footprint(floor: low, bottom: -1.4),
        Footprint(floor: high, bottom: -0.73),
        Footprint(kind: .wall, center: [6, 4], size: [4, 0.1], yaw: 0, bottom: -0.73, height: 2.6),
        Footprint(kind: .window, center: [6, 4.01], size: [1, 0.1], yaw: 0, bottom: 0.17, height: 1),
    ], points: [])

    let scene = try #require(VenueScene.make(from: map))

    for floor in scene.surfaces where floor.kind == "floor" { #expect(height(of: floor.mapFromSurface) == -1.4) }
    let wall = try #require(scene.surfaces.first { $0.kind == "wall" })
    #expect(abs(height(of: wall.mapFromSurface) - (-1.4 + 1.3)) < 1e-4)
    // The window keeps its 0.9 m sill above its own room's floor.
    let window = try #require(scene.surfaces.first { $0.kind == "window" })
    #expect(abs(height(of: window.mapFromSurface) - (-1.4 + 0.9 + 0.5)) < 1e-4)
}

@Test func polygonContainsPointsInsideAnLShape() {
    let room: [SIMD2<Float>] = [[0, 0], [6, 0], [6, 3], [3, 3], [3, 6], [0, 6]]
    #expect(Polygon.contains([1, 5], in: room))
    #expect(!Polygon.contains([5, 5], in: room))
}
