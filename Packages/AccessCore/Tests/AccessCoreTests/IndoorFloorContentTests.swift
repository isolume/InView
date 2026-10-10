import Foundation
import simd
import Testing
@testable import AccessCore

private let stairsSightingID = UUID(uuidString: "7CCAD464-DF52-40B8-9355-C81DAE725F27")!

private func contentPose(x: Float = 0, y: Float = 0, z: Float = 0) -> [Float] {
    [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]
}

private func contentScene(objects: [CaptureObject] = []) throws -> ProcessedScene {
    let capture = CaptureBundle(id: "building-scan", mapID: "building", objects: objects, surfaces: [
        CaptureSurface(id: "ground", kind: "floor", mapFromSurface: contentPose(y: -1.3), dimensionsM: [8, 0, 6]),
        CaptureSurface(id: "ground-wall", kind: "wall", mapFromSurface: contentPose(y: 0.1, z: -3), dimensionsM: [8, 2.8, 0]),
        CaptureSurface(id: "upper", kind: "floor", mapFromSurface: contentPose(y: 1.7), dimensionsM: [8, 0, 6]),
        CaptureSurface(id: "upper-wall", kind: "wall", mapFromSurface: contentPose(y: 3.1, z: -3), dimensionsM: [8, 2.8, 0]),
    ])
    return try LocalSceneBuilder.make(from: capture)
}

private func contentStairs(id: UUID? = stairsSightingID) -> Footprint {
    Footprint(kind: .stairs, center: [1.5, -0.8], size: [1.2, 2.1], yaw: .pi / 3, id: id)
}

private func contentMap(footprints: [Footprint]) -> VenueMap {
    VenueMap(createdAt: Date(timeIntervalSince1970: 10), floorY: -1.3, footprints: footprints,
             points: [AccessPoint(kind: .destination, name: "Lobby", position: [3, -1.3, 1], source: .manual, confidence: 1)],
             geographicReference: BuildingMapReference(latitude: 33.75, longitude: -84.39, headingDegrees: 22))
}

@Test func detectedStairsAppearInBothSceneAndMapOnTheRouteFloor() throws {
    let source = try contentScene()
    let stairs = contentStairs()
    let originalMap = contentMap(footprints: [stairs])
    let content = IndoorFloorContent(scene: source, map: originalMap, selectedFloorID: nil)
    #expect(content.isRouteFloor)
    let map = try #require(content.map)
    let scene = try #require(content.scene)
    #expect(map.footprints.filter { $0.kind == .stairs } == [stairs])
    #expect(map.points == originalMap.points)
    #expect(map.geographicReference == originalMap.geographicReference)
    #expect(map.createdAt == originalMap.createdAt)
    let object = try #require(scene.objects.first { $0.sourceID == stairsSightingID.uuidString })
    #expect(object.sourceCategory == "stairs")
    #expect(object.modelKey == "bounds_v1")
    #expect(object.mapFromObject[12] == stairs.center.x)
    #expect(object.mapFromObject[14] == stairs.center.y)
    #expect(abs(atan2(object.mapFromObject[2], object.mapFromObject[0]) - stairs.yaw) < 0.00001)
    #expect(object.measuredDimensionsM == [stairs.size.x, 0.15, stairs.size.y])
    #expect(abs(object.obstacleBounds.min[1] - map.floorY) < 0.00001)
    #expect(abs(object.obstacleBounds.max[1] - map.floorY - 0.15) < 0.00001)
    #expect(Set(object.obstacleCorners.map { SIMD2($0[0], $0[2]) }) == Set(stairs.corners))
    try scene.validate()
}

@Test func mapOnlyStairAnnotationsAreOmittedFromOtherFloors() throws {
    let source = try contentScene()
    let map = contentMap(footprints: [contentStairs()])
    let upstairs = try #require(IndoorSceneFloors.floors(in: source).last)
    let content = IndoorFloorContent(scene: source, map: map, selectedFloorID: upstairs.id)
    #expect(!content.isRouteFloor)
    #expect(content.scene?.surfaces.map(\.sourceID) == ["upper", "upper-wall"])
    #expect(content.scene?.objects.isEmpty == true)
    #expect(content.map?.footprints.contains { $0.kind == .stairs } == false)
    #expect(content.map?.points.isEmpty == true)
    #expect(content.map?.geographicReference == map.geographicReference)
}

@Test func stairDisplayAnnotationsNeverMutateTheSavedSceneOrRoutingMap() throws {
    let source = try contentScene()
    let map = contentMap(footprints: [contentStairs(), Footprint(kind: .wall, center: [0, -3], size: [8, 0.15], yaw: 0)])
    let originalScene = source
    let originalFootprints = map.footprints
    let originalPoints = map.points
    let route = RoutePlanner(map: map).route(from: [-2, 0], to: map.points[0])
    _ = IndoorFloorContent(scene: source, map: map, selectedFloorID: nil)
    _ = IndoorFloorContent(scene: source, map: map, selectedFloorID: IndoorSceneFloors.floors(in: source).last?.id)
    #expect(source == originalScene)
    #expect(source.objects.isEmpty)
    #expect(map.footprints == originalFootprints)
    #expect(map.points == originalPoints)
    #expect(map.floorY == -1.3)
    #expect(RoutePlanner(map: map).route(from: [-2, 0], to: map.points[0])?.waypoints == route?.waypoints)
}

@Test func repeatedSightingsDoNotAddDuplicateStairObjectsOrMapIDs() throws {
    let source = try contentScene()
    let stairs = contentStairs()
    let content = IndoorFloorContent(scene: source, map: contentMap(footprints: [stairs, stairs]), selectedFloorID: nil)
    #expect(content.scene?.objects.map(\.sourceID) == [stairsSightingID.uuidString])
    #expect(content.map?.footprints.filter { $0.id == stairsSightingID } == [stairs])
    let untracked = IndoorFloorContent(scene: source, map: contentMap(footprints: [contentStairs(id: nil)]), selectedFloorID: nil)
    #expect(untracked.scene?.objects.isEmpty == true)
    #expect(untracked.map?.footprints.contains { $0.kind == .stairs } == false)
}

@Test func existingSceneObjectWithTheSightingIDIsNotDuplicated() throws {
    let object = CaptureObject(id: stairsSightingID.uuidString, category: "stairs", confidence: .high,
                               mapFromObject: contentPose(x: 1.5, y: -1.225, z: -0.8), dimensionsM: [1.2, 0.15, 2.1])
    let source = try contentScene(objects: [object])
    let content = IndoorFloorContent(scene: source, map: contentMap(footprints: [contentStairs()]), selectedFloorID: nil)
    #expect(content.scene?.objects == source.objects)
    #expect(content.scene?.objects.count == 1)
    #expect(content.map?.footprints.filter { $0.kind == .stairs } == [contentStairs()])
}

@Test func mapWithoutAProcessedSceneRetainsItsOriginalStairsAndPoints() throws {
    let map = contentMap(footprints: [contentStairs(), contentStairs(id: nil)])
    let content = IndoorFloorContent(scene: nil, map: map, selectedFloorID: "unavailable-level")
    #expect(content.scene == nil)
    #expect(content.floor == nil)
    #expect(content.isRouteFloor)
    #expect(content.map?.footprints == map.footprints)
    #expect(content.map?.points == map.points)
    #expect(content.map?.floorY == map.floorY)
    #expect(content.map?.geographicReference == map.geographicReference)
    #expect(content.map?.createdAt == map.createdAt)
}

@Test func displayFloorRetainsMeasuredConcaveOutlinesInsteadOfSceneBounds() throws {
    let source = try contentScene()
    let outline: [SIMD2<Float>] = [[-4, -3], [4, -3], [4, -1], [0, -1], [0, 3], [-4, 3]]
    let floor = Footprint(floor: outline, bottom: -1.3)
    let map = contentMap(footprints: [floor])
    let content = IndoorFloorContent(scene: source, map: map, selectedFloorID: nil)
    #expect(content.map?.footprints.filter { $0.kind == .floor } == [floor])
    #expect(content.map?.footprints.first { $0.kind == .floor }?.corners == outline)
    #expect(source.surfaces.first?.measuredDimensionsM == [8, 0, 6])
}

@Test func measuredFloorOutlinesNeverLeakBetweenSelectedLevels() throws {
    let source = try contentScene()
    let ground = Footprint(floor: [[-4, -3], [4, -3], [4, 3], [-4, 3]], bottom: -1.3)
    let upstairs = Footprint(floor: [[-2, -2], [2, -2], [0, 2]], bottom: 1.7)
    let map = contentMap(footprints: [ground, upstairs])
    let levels = IndoorSceneFloors.floors(in: source)
    let lowerContent = IndoorFloorContent(scene: source, map: map, selectedFloorID: levels.first?.id)
    let upperContent = IndoorFloorContent(scene: source, map: map, selectedFloorID: levels.last?.id)
    #expect(lowerContent.map?.footprints.filter { $0.kind == .floor } == [ground])
    #expect(upperContent.map?.footprints.filter { $0.kind == .floor } == [upstairs])
    #expect(map.footprints == [ground, upstairs])
}
