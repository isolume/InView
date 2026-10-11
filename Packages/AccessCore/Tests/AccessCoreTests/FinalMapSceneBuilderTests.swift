import Foundation
import Testing
import simd
@testable import AccessCore

@Suite struct FinalMapSceneBuilderTests {
    private func pose(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0, yaw: Float = 0) -> [Float] {
        let c = cos(yaw), s = sin(yaw)
        return [c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, x, y, z, 1]
    }

    private func scene(mesh: SceneMesh? = nil, surfaces: [SceneSurface] = [], objects: [SceneObject] = []) -> ProcessedScene {
        ProcessedScene(sourceScanID: "original-scan", mapID: "original-map", floorID: "original-floor",
            options: SceneProcessingOptions(maxPoints: 500), objects: objects, surfaces: surfaces,
            meshes: mesh.map { [$0] } ?? [],
            pointCloud: [ScenePoint(sourceFrameID: "photo", position: [0, 0, 0], confidence: 2)],
            warnings: ["Original capture warning"])
    }

    private func floor(_ id: String = "measured-floor", x: Float = 0, y: Float = 0, z: Float = 0,
                       width: Float = 4, depth: Float = 4) -> SceneSurface {
        SceneSurface(sourceID: id, kind: "floor", mapFromSurface: pose(x, y, z),
                     measuredDimensionsM: [width, 0, depth], renderDimensionsM: [width, 0.025, depth], color: "#333333")
    }

    private func wall(_ id: String, x: Float = 0, y: Float = 1.2, z: Float = 0,
                      width: Float = 4, height: Float = 2.4, kind: String = "wall") -> SceneSurface {
        SceneSurface(sourceID: id, kind: kind, mapFromSurface: pose(x, y, z),
            measuredDimensionsM: [width, height, 0], renderDimensionsM: [width, height, 0.025], color: "#333333")
    }

    private func object(_ id: String = "furniture", x: Float = 0, y: Float = 0.5, z: Float = 0,
                        size: [Float] = [1, 1, 1], key: String = "chair_v2") -> SceneObject {
        let corners: [[Float]] = (0..<8).map { index in
            [x + size[0] * (index & 1 == 0 ? -0.5 : 0.5),
             y + size[1] * (index & 2 == 0 ? -0.5 : 0.5),
             z + size[2] * (index & 4 == 0 ? -0.5 : 0.5)]
        }
        return SceneObject(sourceID: id, sourceCategory: "chair", sourceConfidence: .high, modelKey: key,
            mapFromObject: pose(x, y, z), measuredDimensionsM: size, obstacleCorners: corners,
            obstacleBounds: SceneBounds(min: [x - size[0] / 2, y - size[1] / 2, z - size[2] / 2],
                                       max: [x + size[0] / 2, y + size[1] / 2, z + size[2] / 2]),
            parts: [SceneModelPart(center: [0, 0, 0], dimensionsM: size, color: "#333333")])
    }

    private struct MeshFixture {
        var vertices: [[Float]] = []
        var triangles: [[Int]] = []
        mutating func quad(_ a: [Float], _ b: [Float], _ c: [Float], _ d: [Float]) {
            let start = vertices.count
            vertices.append(contentsOf: [a, b, c, d])
            triangles.append(contentsOf: [[start, start + 1, start + 2], [start, start + 2, start + 3]])
        }
        mutating func floor(x0: Float, z0: Float, x1: Float, z1: Float, y: Float = 0) {
            quad([x0, y, z0], [x1, y, z0], [x1, y, z1], [x0, y, z1])
        }
        mutating func wall(x0: Float, x1: Float, z: Float, y0: Float = 0, y1: Float = 2.4) {
            quad([x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z])
        }
        var mesh: SceneMesh { SceneMesh(sourceID: "stream-depth-fusion", vertices: vertices, triangles: triangles) }
    }

    private func world(_ point: [Float], surface: SceneSurface) -> SIMD3<Float> {
        let m = surface.mapFromSurface
        let x = m[0] * point[0] + m[4] * point[1] + m[8] * point[2] + m[12]
        let y = m[1] * point[0] + m[5] * point[1] + m[9] * point[2] + m[13]
        let z = m[2] * point[0] + m[6] * point[1] + m[10] * point[2] + m[14]
        return SIMD3(x, y, z)
    }

    private func coversFloor(_ scene: ProcessedScene, _ point: SIMD2<Float>, elevation: Float = 0) -> Bool {
        scene.surfaces.filter { $0.kind == "floor" && abs($0.mapFromSurface[13] - elevation) < 0.1 }.contains { surface in
            let corners = surface.polygonCorners ?? [
                [-surface.measuredDimensionsM[0] / 2, 0, -surface.measuredDimensionsM[2] / 2],
                [surface.measuredDimensionsM[0] / 2, 0, -surface.measuredDimensionsM[2] / 2],
                [surface.measuredDimensionsM[0] / 2, 0, surface.measuredDimensionsM[2] / 2],
                [-surface.measuredDimensionsM[0] / 2, 0, surface.measuredDimensionsM[2] / 2],
            ]
            let polygon = corners.map { world($0, surface: surface) }.map { SIMD2($0.x, $0.z) }
            var inside = false
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }
    }

    private func coversWall(_ scene: ProcessedScene, x: Float, y: Float, z: Float) -> Bool {
        scene.surfaces.filter { $0.kind == "wall" }.contains { surface in
            let m = surface.mapFromSurface
            let offset = SIMD3(x - m[12], y - m[13], z - m[14])
            let localX = simd_dot(offset, SIMD3(m[0], m[1], m[2]))
            let localY = simd_dot(offset, SIMD3(m[4], m[5], m[6]))
            let localZ = simd_dot(offset, SIMD3(m[8], m[9], m[10]))
            return abs(localX) < surface.measuredDimensionsM[0] / 2
                && abs(localY) < surface.measuredDimensionsM[1] / 2 && abs(localZ) < 0.15
        }
    }

    @Test func roughMeshBecomesFlatFloorsAndUprightWallsWithoutChangingCapture() throws {
        var fixture = MeshFixture()
        fixture.quad([-3, -0.01, -3], [3, 0.01, -3], [3, 0.02, 3], [-3, 0, 3])
        fixture.quad([-3, 0, -3.01], [3, 0, -2.99], [3, 2.4, -3.02], [-3, 2.4, -3])
        fixture.floor(x0: -0.5, z0: -0.5, x1: 0.5, z1: 0.5, y: 0.9) // Tabletop.
        fixture.quad([1, 0.2, 1], [1.1, 0.5, 1.15], [0.9, 0.65, 1], [1, 0.3, 0.9]) // Clutter.
        let source = scene(mesh: fixture.mesh, objects: [object(x: 1, z: 1)])
        let snapshot = source
        let result = try FinalMapSceneBuilder.make(from: source, floorY: 0)
        #expect(result.meshes.isEmpty && result.pointCloud.isEmpty)
        #expect(coversFloor(result, [2, 1]))
        #expect(coversWall(result, x: 2, y: 1, z: -3))
        #expect(result.surfaces.filter { $0.kind == "floor" }.allSatisfy { $0.mapFromSurface[13] == 0 })
        #expect(!result.surfaces.contains { $0.kind == "floor" && $0.mapFromSurface[13] > 0.1 })
        #expect(result.sourceScanID == source.sourceScanID && result.mapID == source.mapID && result.floorID == source.floorID)
        #expect(result.coordinates == source.coordinates && result.options == source.options && result.warnings == source.warnings)
        #expect(result.objects[0].sourceID == source.objects[0].sourceID)
        #expect(result.objects[0].mapFromObject == source.objects[0].mapFromObject)
        #expect(result.objects[0].obstacleBounds == source.objects[0].obstacleBounds)
        #expect(source == snapshot)
        try result.validate()
    }

    @Test func concaveCoverageDisconnectedRoomsAndCourtyardHolesRemainUnfilled() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: 0, z0: 0, x1: 5, z1: 1)
        fixture.floor(x0: 0, z0: 1, x1: 1, z1: 5)
        fixture.floor(x0: 4, z0: 1, x1: 5, z1: 5)
        fixture.floor(x0: 1, z0: 4, x1: 4, z1: 5)
        fixture.floor(x0: 6, z0: 0, x1: 8, z1: 2)
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh), floorY: 0)
        #expect(coversFloor(result, [0.5, 2.5]))
        #expect(coversFloor(result, [7, 1]))
        #expect(!coversFloor(result, [2.5, 2.5]))
        #expect(!coversFloor(result, [5.5, 1]))
        #expect(!coversFloor(result, [8.5, 1]))
    }

    @Test func cellCoverageUsesActualTrianglesRatherThanCentersOrBounds() throws {
        var fixture = MeshFixture()
        // Two substantial floor halves with a narrow but real unobserved seam between them.
        fixture.floor(x0: 0, z0: 0, x1: 1.02, z1: 3)
        fixture.floor(x0: 1.08, z0: 0, x1: 3, z1: 3)
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh), floorY: 0)
        #expect(coversFloor(result, [0.5, 1]))
        #expect(coversFloor(result, [2, 1]))
        #expect(!coversFloor(result, [1.05, 1]))
    }

    @Test func noiseAndFarFragmentsCannotExpandTheFinalMapBounds() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -2, z0: -2, x1: 2, z1: 2)
        fixture.floor(x0: 70, z0: 70, x1: 70.8, z1: 70.8)
        fixture.floor(x0: 5, z0: 5, x1: 5.2, z1: 5.2)
        fixture.quad([-1, 0, -1], [100, 0, 100], [101, 0, 100], [-1, 0, -1.1])
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh), floorY: 0)
        #expect(coversFloor(result, [1, 1]))
        #expect(!coversFloor(result, [70.4, 70.4]))
        #expect(!coversFloor(result, [5.1, 5.1]))
        #expect(result.surfaces.allSatisfy { abs($0.mapFromSurface[12]) <= 2 && abs($0.mapFromSurface[14]) <= 2 })
    }

    @Test func floorInferenceIgnoresTinyLowNoiseTabletopsAndCeilings() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -2, z0: -2, x1: 2, z1: 2, y: -1.4)
        fixture.floor(x0: -2, z0: -2, x1: 2, z1: 2, y: 1.2)
        fixture.floor(x0: -0.5, z0: -0.5, x1: 0.5, z1: 0.5, y: -0.6)
        fixture.floor(x0: 4, z0: 4, x1: 4.2, z1: 4.2, y: -4)
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh))
        let floors = result.surfaces.filter { $0.kind == "floor" }
        #expect(!floors.isEmpty)
        #expect(floors.allSatisfy { abs($0.mapFromSurface[13] + 1.4) <= 0.12 })
    }

    @Test func selectedFloorRecoversOnlyItsStoryAndRetainsCoordinateFrame() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: 10, z0: 20, x1: 14, z1: 24, y: -1)
        fixture.wall(x0: 10, x1: 14, z: 20, y0: -1, y1: 1.4)
        fixture.floor(x0: 10, z0: 20, x1: 14, z1: 24, y: 2)
        fixture.wall(x0: 10, x1: 14, z: 20, y0: 2, y1: 4.4)
        let source = scene(mesh: fixture.mesh,
            surfaces: [floor("lower", x: 12, y: -1, z: 22, width: 0.3, depth: 0.3),
                       floor("upper", x: 12, y: 2, z: 22, width: 0.3, depth: 0.3)],
            objects: [object("lower-chair", x: 12, y: -0.5, z: 22), object("upper-chair", x: 12, y: 2.5, z: 22)])
        let result = try FinalMapSceneBuilder.make(from: source, floorY: 2)
        #expect(result.objects.map(\.sourceID) == ["upper-chair"])
        #expect(!result.surfaces.contains { $0.sourceID == "lower" })
        #expect(coversFloor(result, [11, 21], elevation: 2))
        #expect(!coversFloor(result, [11, 21], elevation: -1))
        #expect(result.surfaces.filter { $0.kind == "floor" }.allSatisfy { $0.mapFromSurface[13] == 2 })
        #expect(coversWall(result, x: 11, y: 3, z: 20))
        #expect(!coversWall(result, x: 11, y: 0, z: 20))
        #expect(result.floorID == source.floorID && result.mapID == source.mapID)
    }

    @Test func authoritativeConcaveFootprintReplacesBroadFloorAnchor() throws {
        let polygon: [SIMD2<Float>] = [[10, 20], [14, 20], [14, 21], [11, 21], [11, 24], [10, 24]]
        let footprint = Footprint(floor: polygon, bottom: -1.3)
        let source = scene(surfaces: [floor("original-floor-id", x: 12, y: -1.3, z: 22)])
        let result = try FinalMapSceneBuilder.make(from: source, floorFootprints: [footprint], floorY: -1.3)
        let surface = try #require(result.surfaces.first)
        #expect(surface.sourceID == "original-floor-id")
        #expect(surface.polygonCorners?.map { world($0, surface: surface) }.map { SIMD2($0.x, $0.z) } == polygon)
        #expect(coversFloor(result, [10.5, 23], elevation: -1.3))
        #expect(!coversFloor(result, [12, 23], elevation: -1.3))
        #expect(source.surfaces[0].polygonCorners == nil)
    }

    @Test func recoveryKeepsAnOffsetAndRotatedMeasuredMapInItsOriginalFrame() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -2, z0: -2, x1: 2, z1: 2, y: -1.3)
        fixture.wall(x0: -2, x1: 2, z: -2, y0: -1.3, y1: 1.1)
        let rotation: Float = 0.6
        let matrix = pose(20, 0, 30, yaw: rotation)
        var transformed = fixture.mesh
        transformed.vertices = fixture.vertices.map { p in
            [matrix[0] * p[0] + matrix[8] * p[2] + matrix[12], p[1],
             matrix[2] * p[0] + matrix[10] * p[2] + matrix[14]]
        }
        let source = scene(mesh: transformed)
        let result = try FinalMapSceneBuilder.make(from: source, floorY: -1.3)
        #expect(coversFloor(result, [20, 30], elevation: -1.3))
        #expect(!coversFloor(result, [0, 0], elevation: -1.3))
        let sample = SIMD2<Float>(20 + cos(rotation) + 2 * sin(rotation), 30 + sin(rotation) - 2 * cos(rotation))
        #expect(coversWall(result, x: sample.x, y: -0.3, z: sample.y))
        #expect(result.surfaces.allSatisfy { validRigidTransform($0.mapFromSurface) })
        #expect(source.meshes[0].vertices == transformed.vertices)
    }

    @Test func tinySemanticFloorDoesNotSuppressSupportedMeasuredRoom() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -3, z0: -3, x1: 3, z1: 3)
        let measured = floor(width: 0.5, depth: 0.5)
        let source = scene(mesh: fixture.mesh, surfaces: [measured])
        let result = try FinalMapSceneBuilder.make(from: source)
        #expect(coversFloor(result, [2, 2]))
        #expect(coversFloor(result, [0, 0]))
        #expect(result.surfaces.first?.sourceID == measured.sourceID)
        #expect(result.surfaces.first?.mapFromSurface == measured.mapFromSurface)
        #expect(result.surfaces.first?.measuredDimensionsM == measured.measuredDimensionsM)
    }

    @Test func measuredOpeningsSurviveSpuriousFusionAndKnownWallsAreNotDoubled() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -3, z0: -3, x1: 3, z1: 3)
        fixture.wall(x0: -3, x1: 3, z: -3)
        let measuredWall = wall("known-wall", x: -2, z: -3, width: 1)
        let opening = wall("door", y: 1, z: -3, width: 0.9, height: 2, kind: "door")
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh, surfaces: [measuredWall, opening]), floorY: 0)
        #expect(coversWall(result, x: 2, y: 1, z: -3))
        #expect(!coversWall(result, x: 0, y: 1, z: -3))
        #expect(result.surfaces.contains { $0.sourceID == opening.sourceID && $0.mapFromSurface == opening.mapFromSurface })
        let recoveredWalls = result.surfaces.filter { $0.kind == "wall" && $0.sourceID != measuredWall.sourceID }
        #expect(!recoveredWalls.contains { surface in
            let oneWallScene = scene(surfaces: [surface])
            return coversWall(oneWallScene, x: -2, y: 1, z: -3)
        })
    }

    @Test func meshDoorGapAndShortFurnitureSidesArePreserved() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -3, z0: -3, x1: 3, z1: 3)
        fixture.wall(x0: -3, x1: -0.6, z: -3)
        fixture.wall(x0: 0.6, x1: 3, z: -3)
        fixture.wall(x0: -0.6, x1: 0.6, z: -3, y0: 2, y1: 2.4)
        fixture.wall(x0: -1, x1: 1, z: 0, y1: 0.9)
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh), floorY: 0)
        #expect(coversWall(result, x: 2, y: 1, z: -3))
        #expect(!coversWall(result, x: 0, y: 1, z: -3))
        #expect(!coversWall(result, x: 0, y: 0.5, z: 0))
    }

    @Test func disconnectedHighAndLowFragmentsCannotCollectivelyBecomeAWall() throws {
        var fixture = MeshFixture()
        fixture.floor(x0: -4, z0: -3, x1: 4, z1: 3)
        // These broad fragments share one plane and together span a full story, but neither
        // is a continuous floor-supported wall. They previously passed the plane-wide test.
        fixture.wall(x0: -2, x1: 2, z: -3, y0: 0, y1: 0.6)
        fixture.wall(x0: -2, x1: 2, z: -3, y0: 1.4, y1: 2.4)
        // A separate, genuinely upright observation on that same plane must survive.
        fixture.wall(x0: -3.6, x1: -2.8, z: -3)
        let anchor = wall("measured-anchor", x: 2.5, y: 0.3, z: -3, width: 0.5, height: 0.6)
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh, surfaces: [anchor]), floorY: 0)
        #expect(!coversWall(result, x: 0, y: 0.3, z: -3))
        #expect(!coversWall(result, x: 0, y: 1.8, z: -3))
        #expect(coversWall(result, x: -3.15, y: 1, z: -3))
        #expect(result.surfaces.contains { $0.sourceID == anchor.sourceID
            && $0.mapFromSurface == anchor.mapFromSurface && $0.measuredDimensionsM == anchor.measuredDimensionsM })
    }

    @Test func duplicateWallsCoalesceConservativelyWithoutJoiningPassageGaps() throws {
        let original = wall("first", x: -1, z: 2, width: 2)
        let duplicate = wall("duplicate", x: -0.7, z: 2.01, width: 2)
        let separate = wall("after-gap", x: 2, z: 2, width: 2)
        let result = try FinalMapSceneBuilder.make(from: scene(surfaces: [original, duplicate, separate]))
        #expect(result.surfaces.map(\.sourceID) == ["first", "after-gap"])
        #expect(abs(result.surfaces[0].measuredDimensionsM[0] - 2.3) < 0.001)
        #expect(!coversWall(result, x: 0.65, y: 1, z: 2))
    }

    @Test func knownFurnitureKeepsItsModelAndUnknownFurnitureUsesOneCleanBound() throws {
        let mesh = SceneModelMesh(name: "chair-model", vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]],
            normals: [[0, 0, 1], [0, 0, 1], [0, 0, 1]], triangles: [[0, 1, 2]], color: "#010101")
        var known = object("known")
        known.modelMeshes = [mesh]
        var unknown = object("unknown", x: 2, key: "bounds_v1")
        unknown.modelMeshes = [mesh]
        unknown.parts.append(SceneModelPart(center: [0.2, 0.2, 0.2], dimensionsM: [0.1, 0.1, 0.1], color: "#222222"))
        let result = try FinalMapSceneBuilder.make(from: scene(objects: [known, unknown]))
        #expect(result.objects[0].modelMeshes[0].vertices == mesh.vertices)
        #expect(result.objects[0].modelMeshes[0].triangles == mesh.triangles)
        #expect(result.objects[1].modelMeshes.isEmpty)
        #expect(result.objects[1].parts.count == 1)
        #expect(result.objects[1].parts[0].dimensionsM == unknown.measuredDimensionsM)
        #expect(result.objects[1].obstacleCorners == unknown.obstacleCorners)
    }

    @Test func preprocessingIsDeterministicAndDoesNotCreateAFloorWithoutEvidence() throws {
        let noFloor = scene(surfaces: [wall("wall")])
        let empty = try FinalMapSceneBuilder.make(from: noFloor)
        #expect(!empty.surfaces.contains { $0.kind == "floor" })
        var fixture = MeshFixture()
        fixture.floor(x0: -2, z0: -2, x1: 2, z1: 2)
        let source = scene(mesh: fixture.mesh)
        #expect(try FinalMapSceneBuilder.make(from: source, floorY: 0) == FinalMapSceneBuilder.make(from: source, floorY: 0))
    }

    @Test func validationRejectsInvalidCoordinatesAndOversizedInputs() throws {
        var invalid = scene(surfaces: [floor()])
        invalid.surfaces[0].mapFromSurface[12] = .nan
        #expect(throws: SceneValidationError.self) { try FinalMapSceneBuilder.validateInput(invalid) }
        #expect(throws: SceneValidationError.self) { try FinalMapSceneBuilder.make(from: invalid) }
        #expect(throws: SceneValidationError.self) { try FinalMapSceneBuilder.make(from: scene(), floorY: .infinity) }
        var fixture = MeshFixture()
        fixture.floor(x0: 0, z0: 0, x1: 1, z1: 1)
        var excessive = fixture.mesh
        excessive.triangles = Array(repeating: [0, 1, 2], count: 200_001)
        #expect(throws: SceneValidationError.self) { try FinalMapSceneBuilder.validateInput(scene(mesh: excessive)) }
    }

    @Test func canceledPreparationThrowsBeforePublishingAPartialMap() async {
        let source = scene(surfaces: [floor()])
        let task = Task { () throws -> ProcessedScene in
            withUnsafeCurrentTask { $0?.cancel() }
            return try FinalMapSceneBuilder.make(from: source)
        }
        do {
            _ = try await task.value
            Issue.record("Canceled map preparation returned a scene.")
        } catch { #expect(error is CancellationError) }
    }

    @Test func denseFiftyThousandFaceScanProducesBoundedStructuralGeometry() throws {
        var fixture = MeshFixture()
        let count = 160
        for z in 0..<count {
            for x in 0..<count {
                fixture.floor(x0: Float(x) * 0.04, z0: Float(z) * 0.04,
                              x1: Float(x + 1) * 0.04, z1: Float(z + 1) * 0.04)
            }
        }
        #expect(fixture.triangles.count == 51_200)
        let result = try FinalMapSceneBuilder.make(from: scene(mesh: fixture.mesh), floorY: 0)
        #expect(coversFloor(result, [3, 3]))
        #expect(result.surfaces.count < 20)
        #expect(result.meshes.isEmpty)
    }
}
