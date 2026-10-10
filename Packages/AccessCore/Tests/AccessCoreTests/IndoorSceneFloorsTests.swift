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

private func measuredStreamMesh(floorY: Float, height: Float = 2.6) -> SceneMesh {
    let top = floorY + height
    // A depth-only scan can measure a large room while its semantic floor anchor stays tiny.
    return SceneMesh(sourceID: "stream-depth-fusion", vertices: [
        [-6, floorY, -4], [6, floorY, -4], [6, floorY, 4], [-6, floorY, 4],
        [-6, top, -4], [6, top, -4], [6, top, 4], [-6, top, 4],
    ], triangles: [[0, 2, 1], [0, 3, 2], [0, 1, 5], [0, 5, 4], [4, 5, 6], [4, 6, 7]])
}

private func measuredFaces(_ mesh: SceneMesh) -> [[[Float]]] {
    mesh.triangles.map { $0.map { mesh.vertices[$0] } }
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

@Test func continuousScanCutawayKeepsMeasuredWallsAndTheFloorBeyondSparseAnchors() throws {
    var source = floorScene([floorSurface("tiny-anchor", elevation: -1.2, size: [0.8, 0, 0.7])])
    let measured = measuredStreamMesh(floorY: -1.5)
    source.meshes = [measured]
    let saved = source
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    let result = IndoorSceneFloors.scene(source, on: selected)
    let displayed = try #require(result.meshes.first)
    #expect(displayed.sourceID == "stream-depth-fusion")
    #expect(measuredFaces(displayed) == Array(measuredFaces(measured).prefix(4)))
    #expect(displayed.vertices.contains([-6, -1.5, -4]))
    #expect(displayed.vertices.contains([6, -1.5, 4]))
    #expect(displayed.vertices.contains(measured.vertices[4]))
    #expect(result.surfaces == source.surfaces)
    #expect(source == saved)
    try result.validate()
}

@Test func streamCutawaysKeepLowHorizontalSurfacesAndRemoveClassifiedCeilings() throws {
    var source = floorScene([floorSurface("floor", elevation: 0)])
    var measured = measuredStreamMesh(floorY: 0, height: 1.8)
    // Explicit ceiling labels must be honored even below the unclassified overhead threshold.
    measured.classifications = ["floor", "floor", "wall", "wall", "ceiling", "ceiling"]
    source.meshes = [measured]
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    let result = IndoorSceneFloors.scene(source, on: selected)
    #expect(result.meshes.first?.classifications == ["floor", "floor", "wall", "wall"])
    #expect(result.meshes.first.map(measuredFaces) == Array(measuredFaces(measured).prefix(4)))

    measured.classifications = nil
    source.meshes = [measured]
    // A horizontal furniture top at 1.8m must not be treated as an unclassified ceiling.
    let lowerHorizontal = IndoorSceneFloors.scene(source, on: selected)
    #expect(lowerHorizontal.meshes.first.map(measuredFaces) == measuredFaces(measured))
}

@Test func streamMeshFloorSwitchingKeepsSelectedMeasuredGeometryAndClipsCrossingFaces() throws {
    var source = floorScene([floorSurface("ground", elevation: 0), floorSurface("upper", elevation: 3)])
    let lower = measuredStreamMesh(floorY: 0)
    let upper = measuredStreamMesh(floorY: 3)
    let measured = SceneMesh(sourceID: lower.sourceID, vertices: lower.vertices + upper.vertices,
                             triangles: lower.triangles + upper.triangles.map { $0.map { $0 + lower.vertices.count } })
    source.meshes = [measured]
    let levels = IndoorSceneFloors.floors(in: source)
    let lowerResult = IndoorSceneFloors.scene(source, on: levels[0])
    let upperResult = IndoorSceneFloors.scene(source, on: levels[1])
    #expect(lowerResult.meshes.first.map(measuredFaces) == Array(measuredFaces(lower).prefix(4)))
    #expect(upperResult.meshes.first.map(measuredFaces) == Array(measuredFaces(upper).prefix(4)))
    let cutaway = IndoorSceneFloors.scene(source, on: levels[1], includeLowerFloors: true)
    #expect(cutaway.meshes.first?.triangles.count == 8)

    // A triangle crossing the next story must be cut along the boundary, rather than vanish.
    source.meshes = [SceneMesh(sourceID: "stream-depth-fusion", vertices: [[0, 0, 0], [1, 0, 0], [0, 4, 0]],
                               triangles: [[0, 1, 2]], classifications: ["wall"])]
    let clipped = try #require(IndoorSceneFloors.scene(source, on: levels[0]).meshes.first)
    #expect(clipped.triangles.count == 2)
    #expect(clipped.classifications == ["wall", "wall"])
    #expect(clipped.vertices.map { $0[1] }.max() == 2.975)
    #expect(clipped.vertices.contains([0, 0, 0]))
    #expect(clipped.vertices.contains([1, 0, 0]))
    let area = measuredFaces(clipped).reduce(Float(0)) { area, face in
        area + abs((face[1][0] - face[0][0]) * (face[2][1] - face[0][1])
                   - (face[1][1] - face[0][1]) * (face[2][0] - face[0][0])) / 2
    }
    #expect(abs(area - (2 - (4 - 2.975) * (4 - 2.975) / 8)) < 0.00001)
    try IndoorSceneFloors.scene(source, on: levels[0]).validate()
}

@Test func streamMeshFilteringRejectsMalformedFacesAndUnknownDisplayFloors() throws {
    var source = floorScene([floorSurface("floor", elevation: 0)])
    let measured = measuredStreamMesh(floorY: 0)
    source.meshes = [SceneMesh(sourceID: measured.sourceID,
                               vertices: measured.vertices + [[0, .nan, 0]],
                               triangles: measured.triangles + [[0, 1], [-1, 0, 1], [0, 1, 8], [0, 0, 0]])]
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    let result = IndoorSceneFloors.scene(source, on: selected)
    #expect(result.meshes.first.map(measuredFaces) == Array(measuredFaces(measured).prefix(4)))
    try result.validate()
    let unknown = IndoorSceneFloors.scene(source, on: IndoorSceneFloor(id: "unknown", title: "Floor 9", elevation: 9))
    #expect(unknown.meshes.isEmpty)
    #expect(unknown.pointCloud.isEmpty)
}

@Test func measuredMeshDisplayCutawayCapsWallsWithoutDroppingCrossingTriangles() throws {
    let measured = measuredStreamMesh(floorY: 0)
    let saved = measured
    let cutaway = try #require(IndoorSceneFloors.cutawayMesh(measured, floorY: 0, wallHeight: 1.05))
    #expect(cutaway.vertices.map { $0[1] }.max() == 1.05)
    #expect(Array(measuredFaces(cutaway).prefix(2)) == Array(measuredFaces(measured).prefix(2)))
    #expect(cutaway.triangles.count == 5)
    let wallArea = measuredFaces(cutaway).dropFirst(2).reduce(Float(0)) { area, face in
        area + abs((face[1][0] - face[0][0]) * (face[2][1] - face[0][1])
                   - (face[1][1] - face[0][1]) * (face[2][0] - face[0][0])) / 2
    }
    #expect(abs(wallArea - 12 * 1.05) < 0.00001)
    let flat = try #require(IndoorSceneFloors.cutawayMesh(measured, floorY: 0, wallHeight: 0.12))
    #expect(flat.vertices.map { $0[1] }.max() == 0.12)
    #expect(measured == saved)
    #expect(IndoorSceneFloors.cutawayMesh(measured, floorY: .nan, wallHeight: 1) == nil)
    #expect(IndoorSceneFloors.cutawayMesh(measured, floorY: 0, wallHeight: 0) == nil)
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

/// One triangle per entry: three corners at `base`, `base`, `top`, so its lowest corner is `base`.
private func labeledMesh(_ faces: [(label: String, base: Float, top: Float)]) -> SceneMesh {
    var vertices: [[Float]] = []
    var triangles: [[Int]] = []
    for (index, face) in faces.enumerated() {
        let x = Float(index)
        vertices.append(contentsOf: [[x, face.base, 0], [x + 1, face.base, 0], [x, face.top, 1]])
        triangles.append([index * 3, index * 3 + 1, index * 3 + 2])
    }
    return SceneMesh(sourceID: ReconstructedMesh.sourceID, vertices: vertices, triangles: triangles,
                     classifications: faces.map(\.label))
}

@Test func singleLevelCutawaysKeepALabeledMeshUnchanged() throws {
    var source = floorScene([floorSurface("room", elevation: 0)])
    let mesh = labeledMesh([("floor", 0, 0), ("wall", 0, 2.6), ("ceiling", 2.7, 2.7)])
    source.meshes = [mesh]
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    // Renderers leave the ceiling out; keeping the same mesh avoids recutting it on every update.
    #expect(IndoorSceneFloors.scene(source, on: selected).meshes == [mesh])
}

@Test func multilevelCutawaysKeepEachLevelsLabeledFacesWithoutItsCeiling() throws {
    var source = floorScene([floorSurface("ground", elevation: 0), floorSurface("upper", elevation: 3)])
    source.meshes = [labeledMesh([
        ("floor", 0, 0), ("wall", 0.1, 2.6),
        // The top of a ground-floor wall stays downstairs; its ceiling goes.
        ("wall", 2.0, 2.8), ("ceiling", 2.8, 2.8),
        ("floor", 3, 3), ("seat", 3.05, 3.5),
    ])]
    let floors = IndoorSceneFloors.floors(in: source)
    #expect(floors.count == 2)
    let ground = try #require(IndoorSceneFloors.scene(source, on: floors[0]).meshes.first)
    #expect(ground.classifications == ["floor", "wall", "wall"])
    #expect(ground.vertices.count == 9)
    #expect(ground.vertices.allSatisfy { $0[1] < 3 })
    let upper = try #require(IndoorSceneFloors.scene(source, on: floors[1]).meshes.first)
    #expect(upper.classifications == ["floor", "seat"])
    #expect(upper.triangles == [[0, 1, 2], [3, 4, 5]])
    let both = try #require(IndoorSceneFloors.scene(source, on: floors[1], includeLowerFloors: true).meshes.first)
    #expect(both.classifications == ["floor", "wall", "wall", "floor", "seat"])
    // Repeated SwiftUI updates reuse the cut.
    #expect(IndoorSceneFloors.scene(source, on: floors[1]).meshes.first == upper)
}

@Test func multilevelCutawaysKeepEachVertexsColor() throws {
    var source = floorScene([floorSurface("ground", elevation: 0), floorSurface("upper", elevation: 3)])
    var mesh = labeledMesh([("floor", 0, 0), ("floor", 3, 3)])
    mesh.colors = (0..<UInt32(mesh.vertices.count)).map { $0 * 0x10 }
    source.meshes = [mesh]
    let floors = IndoorSceneFloors.floors(in: source)
    let upper = try #require(IndoorSceneFloors.scene(source, on: floors[1]).meshes.first)
    #expect(upper.colors == [0x30, 0x40, 0x50])
    #expect(upper.vertices == Array(mesh.vertices[3...5]))
}

@Test func cutawayCacheTracksChangedGeometryColorsAndLabelsWithTheSameFaceCount() throws {
    var source = floorScene([floorSurface("ground", elevation: 0), floorSurface("upper", elevation: 3)])
    var mesh = labeledMesh([("floor", 0, 0), ("floor", 3, 3)])
    mesh.colors = Array(repeating: 0xFF0000, count: mesh.vertices.count)
    source.meshes = [mesh]
    let upper = IndoorSceneFloors.floors(in: source)[1]
    let first = try #require(IndoorSceneFloors.scene(source, on: upper).meshes.first)
    mesh.vertices = mesh.vertices.map { [$0[0] + 10, $0[1], $0[2]] }
    mesh.colors = Array(repeating: 0x0000FF, count: mesh.vertices.count)
    source.meshes = [mesh]
    let revised = try #require(IndoorSceneFloors.scene(source, on: upper).meshes.first)
    #expect(revised.vertices == first.vertices.map { [$0[0] + 10, $0[1], $0[2]] })
    #expect(revised.colors == [0x0000FF, 0x0000FF, 0x0000FF])
    mesh.classifications = ["floor", "ceiling"]
    source.meshes = [mesh]
    #expect(IndoorSceneFloors.scene(source, on: upper).meshes.isEmpty)
}

@Test func floorSelectionKeepsBothStreamAndClassifiedDetailMeshes() throws {
    var source = floorScene([floorSurface("floor", elevation: 0)])
    source.meshes = [measuredStreamMesh(floorY: 0), labeledMesh([("floor", 0, 0)])]
    let selected = try #require(IndoorSceneFloors.floors(in: source).first)
    let result = IndoorSceneFloors.scene(source, on: selected)
    #expect(Set(result.meshes.map(\.sourceID)) == ["stream-depth-fusion", ReconstructedMesh.sourceID])
    #expect(result.surfaces == source.surfaces)
}

@Test func coloredDetailCutawaysInterpolateNewBoundaryVertices() throws {
    let mesh = SceneMesh(sourceID: ReconstructedMesh.sourceID,
                         vertices: [[0, 0, 0], [2, 0, 0], [0, 2, 0]], triangles: [[0, 1, 2]],
                         classifications: ["wall"], colors: [0xFF0000, 0xFF0000, 0x0000FF])
    let cut = try #require(IndoorSceneFloors.cutawayMesh(mesh, floorY: 0, wallHeight: 1))
    let colors = try #require(cut.colors)
    #expect(colors.count == cut.vertices.count)
    #expect(cut.triangles.count == 2)
    for (point, color) in zip(cut.vertices, colors) {
        #expect(color == (point[1] == 0 ? 0xFF0000 : 0x800080))
    }
}
