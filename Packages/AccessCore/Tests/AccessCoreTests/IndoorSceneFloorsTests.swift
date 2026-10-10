import Foundation
import Testing
@testable import AccessCore

private func floorPose(x: Float = 0, y: Float, z: Float = 0) -> [Float] {
    [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]
}

private func floorSurface(_ id: String, elevation: Float, x: Float = 0, size: [Float] = [5, 0, 4]) -> SceneSurface {
    SceneSurface(sourceID: id, kind: "floor", mapFromSurface: floorPose(x: x, y: elevation),
                 measuredDimensionsM: size, renderDimensionsM: [size[0], 0.025, size[2]], color: "#eeeeee")
}

private func floorWall(_ id: String, base: Float) -> SceneSurface {
    SceneSurface(sourceID: id, kind: "wall", mapFromSurface: floorPose(y: base + 1.4),
                 measuredDimensionsM: [4, 2.8, 0], renderDimensionsM: [4, 2.8, 0.05], color: "#eeeeee")
}

private func floorObject(_ id: String, base: Float) -> SceneObject {
    SceneObject(sourceID: id, sourceCategory: "chair", sourceConfidence: .high, modelKey: "chair",
                mapFromObject: floorPose(x: 1, y: base + 0.5, z: 2), measuredDimensionsM: [0.5, 1, 0.5],
                obstacleCorners: [], obstacleBounds: SceneBounds(min: [0.75, base, 1.75], max: [1.25, base + 1, 2.25]),
                parts: [SceneModelPart(center: [0, 0, 0], dimensionsM: [0.5, 1, 0.5], color: "#eeeeee")])
}

private func floorScene(_ surfaces: [SceneSurface], objects: [SceneObject] = []) -> ProcessedScene {
    ProcessedScene(sourceScanID: "scan", mapID: "building", floorID: "capture-floor", objects: objects, surfaces: surfaces)
}

@Test func measuredRoomFloorsShareOneDisplayLevelDespiteSmallHeightDifferences() {
    let scene = floorScene([
        floorSurface("room-a", elevation: -1.3),
        floorSurface("room-b", elevation: -1.18, x: 5),
        floorSurface("landing", elevation: -0.9, size: [0.5, 0, 0.5]),
        floorSurface("step", elevation: -0.5, size: [0.3, 0, 0.3]),
    ])
    let floors = IndoorSceneFloors.floors(in: scene)
    #expect(floors.count == 1)
    #expect(floors.first?.title == "Floor 1")
    #expect(abs((floors.first?.elevation ?? 0) + 1.24) < 0.02)
    #expect(IndoorSceneFloors.floors(in: floorScene(scene.surfaces.reversed())) == floors)
}

@Test func selectedFloorRemovesUpstairsGeometryAndLowerFloorsByDefault() throws {
    let scene = floorScene([
        floorSurface("ground-room", elevation: -1.3), floorWall("ground-wall", base: -1.3),
        floorSurface("upper-room", elevation: 1.7), floorWall("upper-wall", base: 1.7),
        floorSurface("third-room", elevation: 4.7), floorWall("third-wall", base: 4.7),
    ], objects: [floorObject("ground-chair", base: -1.3), floorObject("upper-chair", base: 1.7),
                 floorObject("third-chair", base: 4.7), floorObject("below-building", base: -8),
                 floorObject("above-building", base: 12)])
    let floors = IndoorSceneFloors.floors(in: scene)
    #expect(floors.map(\.title) == ["Floor 1", "Floor 2", "Floor 3"])
    let selected = try #require(floors.dropFirst().first)
    let interior = IndoorSceneFloors.scene(scene, on: selected)
    #expect(interior.surfaces.map(\.sourceID) == ["upper-room", "upper-wall"])
    #expect(interior.objects.map(\.sourceID) == ["upper-chair"])
    #expect(interior.floorID == selected.id)

    let cutaway = IndoorSceneFloors.scene(scene, on: selected, includeLowerFloors: true)
    #expect(cutaway.surfaces.map(\.sourceID) == ["ground-room", "ground-wall", "upper-room", "upper-wall"])
    #expect(cutaway.objects.map(\.sourceID) == ["ground-chair", "upper-chair"])
    #expect(scene.surfaces.count == 6)
    #expect(scene.objects.count == 5)
}

@Test func floorFilteringPreservesPartialMeasuredGeometryAndARTransforms() throws {
    let partial = floorSurface("partial-room", elevation: -0.7, x: 19, size: [2.35, 0, 1.1])
    let wall = floorWall("partial-wall", base: -0.7)
    let object = floorObject("partial-chair", base: -0.7)
    let source = floorScene([partial, wall, floorSurface("upstairs", elevation: 2.3)], objects: [object])
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    let interior = IndoorSceneFloors.scene(source, on: selected)
    #expect(interior.surfaces == [partial, wall])
    #expect(interior.objects == [object])
    #expect(interior.sourceScanID == source.sourceScanID)
    #expect(interior.mapID == source.mapID)
    #expect(interior.coordinates == source.coordinates)
    #expect(interior.options == source.options)
    #expect(source.floorID == "capture-floor")
}

@Test func floorInferenceAndWallBasesRespectRotatedLocalAxes() throws {
    // The measured floor is a local XY plane whose normal (local Z) points down in world Y.
    let horizontalPose: [Float] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 2, -1, 3, 1]
    let horizontal = SceneSurface(sourceID: "rotated-floor", kind: "floor", mapFromSurface: horizontalPose,
                                  measuredDimensionsM: [4, 5, 0], renderDimensionsM: [4, 5, 0.025], color: "#eeeeee")
    // Local X is vertical for this wall, so its base comes from transformed width, not local height.
    let wallPose: [Float] = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 2, 0.4, 3, 1]
    let wall = SceneSurface(sourceID: "rotated-wall", kind: "wall", mapFromSurface: wallPose,
                           measuredDimensionsM: [2.8, 4, 0], renderDimensionsM: [2.8, 4, 0.05], color: "#eeeeee")
    let source = floorScene([horizontal, wall, floorSurface("upstairs", elevation: 2)])
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    #expect(selected.elevation == -1)
    #expect(IndoorSceneFloors.scene(source, on: selected).surfaces == [horizontal, wall])
}

@Test func floorCutawaysDiscardCeilingsAndUnclassifiedReconstruction() throws {
    var source = floorScene([floorSurface("room", elevation: 0), floorWall("wall", base: 0)])
    var ceiling = floorSurface("ceiling", elevation: 2.8)
    ceiling.kind = "ceiling"
    source.surfaces.append(ceiling)
    source.meshes = [SceneMesh(sourceID: "mixed-levels", vertices: [[0, 0, 0], [1, 0, 0], [0, 4, 1]], triangles: [[0, 1, 2]])]
    source.pointCloud = [ScenePoint(sourceFrameID: "depth", position: [0, 5, 0])]
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    let result = IndoorSceneFloors.scene(source, on: selected)
    #expect(result.surfaces.map(\.sourceID) == ["room", "wall"])
    #expect(result.meshes.isEmpty)
    #expect(result.pointCloud.isEmpty)
    #expect(source.meshes.count == 1)
    #expect(source.pointCloud.count == 1)
}

@Test func missingOrMalformedFloorMeasurementsProduceNoInventedLevels() {
    var nonfinite = floorSurface("nonfinite", elevation: .nan)
    nonfinite.mapFromSurface[0] = .infinity
    var missingPose = floorSurface("short-transform", elevation: 0)
    missingPose.mapFromSurface = [1, 0]
    var verticalFloor = floorWall("vertical", base: 0)
    verticalFloor.kind = "floor"
    var badDimensions = floorSurface("bad-dimensions", elevation: 0)
    badDimensions.measuredDimensionsM = [1, -.infinity, 1]
    let source = floorScene([nonfinite, missingPose, verticalFloor, badDimensions])
    #expect(IndoorSceneFloors.floors(in: source).isEmpty)
    #expect(IndoorSceneFloors.floors(in: floorScene([floorWall("wall-only", base: 0)])).isEmpty)
    let result = IndoorSceneFloors.scene(source, on: IndoorSceneFloor(id: "unknown", title: "Floor 1", elevation: 0))
    #expect(result.objects.isEmpty)
    #expect(result.surfaces.isEmpty)
}
