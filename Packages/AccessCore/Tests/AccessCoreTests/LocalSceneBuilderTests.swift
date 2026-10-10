import Foundation
import Testing
@testable import AccessCore

private func localPose(x: Float = 0, y: Float = 0, z: Float = 0) -> [Float] {
    [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1]
}

private func localCapture(objects: [CaptureObject] = [], surfaces: [CaptureSurface] = [],
                          meshes: [CaptureMesh] = [], frames: [CaptureDepthFrame] = []) -> CaptureBundle {
    CaptureBundle(id: "local-scan", mapID: "local-building", floorID: "scan-frame",
                  meshes: meshes, frames: frames, objects: objects, surfaces: surfaces)
}

private func localObject(_ category: String, confidence: CaptureConfidence = .high) -> CaptureObject {
    CaptureObject(id: category, category: category, confidence: confidence,
                  mapFromObject: localPose(y: 0.5), dimensionsM: [2, 1, 1])
}

@Test func localSceneRetainsSeparateMeasuredRoomsAndTheirARPoses() throws {
    let roomA = CaptureSurface(id: "room-a", kind: "floor", mapFromSurface: localPose(y: -1.3), dimensionsM: [4, 0, 5])
    // RoomPlan may describe a floor in its local XY plane instead of XZ.
    let roomBPose: [Float] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 7, -1.2, 2, 1]
    let roomB = CaptureSurface(id: "room-b", kind: "floor", mapFromSurface: roomBPose, dimensionsM: [3, 6, 0])
    let upstairs = CaptureSurface(id: "upstairs", kind: "floor", mapFromSurface: localPose(y: 2), dimensionsM: [4, 0, 5])
    let source = localCapture(surfaces: [roomA, roomB, upstairs])
    let result = try LocalSceneBuilder.make(from: source)
    try result.validate(source: source)
    #expect(result.sourceScanID == source.id)
    #expect(result.mapID == source.mapID)
    #expect(result.floorID == source.floorID)
    #expect(result.surfaces.map(\.sourceID) == source.surfaces.map(\.id))
    #expect(result.surfaces.map(\.mapFromSurface) == source.surfaces.map(\.mapFromSurface))
    #expect(result.surfaces.map(\.measuredDimensionsM) == source.surfaces.map(\.dimensionsM))
    #expect(result.surfaces[1].renderDimensionsM == [3, 6, 0.025])
    let floors = IndoorSceneFloors.floors(in: result)
    #expect(floors.count == 2)
    #expect(IndoorSceneFloors.scene(result, on: floors[0]).surfaces.map(\.sourceID) == ["room-a", "room-b"])
    #expect(IndoorSceneFloors.scene(result, on: floors[1]).surfaces.map(\.sourceID) == ["upstairs"])
}

@Test func localObjectBoundsRespectCapturedRotationWithoutMovingTheObject() throws {
    let pose: [Float] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 4, 0.5, 2, 1]
    let chair = CaptureObject(id: "chair", category: "chair", confidence: .high,
                              mapFromObject: pose, dimensionsM: [0.6, 1, 0.5])
    let source = localCapture(objects: [chair])
    let scene = try LocalSceneBuilder.make(from: source)
    let object = try #require(scene.objects.first)
    #expect(object.mapFromObject == pose)
    #expect(object.measuredDimensionsM == chair.dimensionsM)
    #expect(object.obstacleCorners.count == 8)
    #expect(object.obstacleBounds.min == [3.75, 0, 1.7])
    #expect(object.obstacleBounds.max == [4.25, 1, 2.3])
    #expect(Set(object.obstacleCorners.map { $0[0] }) == [3.75, 4.25])
    try scene.validate(source: source)
}

@Test func localFurnitureHasNeutralSemanticPartsWithinMeasuredBounds() throws {
    let source = localCapture(objects: ["chair", "sofa", "table", "bed", "storage", "sink"].map { localObject($0) })
    let scene = try LocalSceneBuilder.make(from: source)
    for object in scene.objects {
        #expect(object.modelKey != "bounds_v1")
        if ["chair", "sofa", "table", "bed"].contains(object.sourceCategory) {
            #expect(object.parts.count > 1)
        }
        for part in object.parts {
            for axis in 0..<3 {
                #expect(abs(part.center[axis]) + part.dimensionsM[axis] / 2 <= object.measuredDimensionsM[axis] / 2 + 0.00001)
            }
            let hex = part.color.dropFirst()
            let channels = stride(from: 0, to: 6, by: 2).map { offset in
                Int(hex.dropFirst(offset).prefix(2), radix: 16)!
            }
            #expect(channels.max()! - channels.min()! <= 8)
        }
    }
    try scene.validate(source: source)
}

@Test func localSceneKeepsUnrecognizedAndLowConfidenceItemsAsMeasuredBoxes() throws {
    let source = localCapture(objects: [localObject("chair", confidence: .low), localObject("unrecognized_fixture")])
    let scene = try LocalSceneBuilder.make(from: source)
    #expect(scene.objects.count == 2)
    for object in scene.objects {
        #expect(object.modelKey == "bounds_v1")
        #expect(object.parts.count == 1)
        #expect(object.parts[0].center == [0, 0, 0])
        #expect(object.parts[0].dimensionsM == object.measuredDimensionsM)
    }
    #expect(!scene.warnings.isEmpty)
    try scene.validate(source: source)
}

@Test func localRawMeshVerticesMoveIntoTheOriginalMapFrame() throws {
    let pose: [Float] = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 4, 2, 3, 1]
    let mesh = CaptureMesh(id: "mesh", mapFromAnchor: pose, vertices: [[0, 0, 0], [1, 0, 0], [0, 1, 0]],
                           triangles: [[0, 1, 2]], classifications: ["wall"])
    let source = localCapture(meshes: [mesh])
    let scene = try LocalSceneBuilder.make(from: source)
    #expect(scene.meshes.first?.vertices == [[4, 2, 3], [4, 2, 2], [4, 3, 3]])
    #expect(scene.meshes.first?.triangles == mesh.triangles)
    #expect(scene.meshes.first?.classifications == mesh.classifications)
    try scene.validate(source: source)
}

@Test func localDepthProjectionUsesARCameraAxesAndConfidence() throws {
    let frame = CaptureDepthFrame(id: "depth", timestampSeconds: 0, mapFromCamera: localPose(y: 2),
                                  camera: CaptureCameraCalibration(imageWidth: 2, imageHeight: 2, fx: 1, fy: 1, cx: 0, cy: 0),
                                  depth: CaptureDepthImage(width: 2, height: 2, valuesM: [1, 2, 1, 0], confidence: [2, 1, 0, 2]))
    let source = localCapture(frames: [frame])
    let scene = try LocalSceneBuilder.make(from: source)
    #expect(scene.pointCloud == [ScenePoint(sourceFrameID: "depth", position: [0, 2, -1], confidence: 2),
                                 ScenePoint(sourceFrameID: "depth", position: [2, 2, -2], confidence: 1)])
    var noConfidence = frame
    noConfidence.depth.confidence = nil
    let excluded = try LocalSceneBuilder.make(from: localCapture(frames: [noConfidence]))
    #expect(excluded.pointCloud.isEmpty)
    #expect(!excluded.warnings.isEmpty)
    try scene.validate(source: source)
}

@Test func localDepthSamplingIsBoundedAndIncludesLaterFrames() throws {
    let camera = CaptureCameraCalibration(imageWidth: 200, imageHeight: 200, fx: 200, fy: 200, cx: 100, cy: 100)
    let depth = CaptureDepthImage(width: 200, height: 200, valuesM: Array(repeating: 1, count: 40_000),
                                  confidence: Array(repeating: 2, count: 40_000))
    let source = localCapture(frames: [
        CaptureDepthFrame(id: "first", timestampSeconds: 0, mapFromCamera: localPose(), camera: camera, depth: depth),
        CaptureDepthFrame(id: "second", timestampSeconds: 1, mapFromCamera: localPose(x: 2), camera: camera, depth: depth),
    ])
    let scene = try LocalSceneBuilder.make(from: source)
    #expect(scene.pointCloud.count == scene.options.maxPoints)
    #expect(Set(scene.pointCloud.map(\.sourceFrameID)) == ["first", "second"])
    try scene.validate(source: source)
}

@Test func navigationSceneSkipsDepthProjectionAndPreservesMeasuredGeometryAndRawSource() throws {
    let camera = CaptureCameraCalibration(imageWidth: 200, imageHeight: 200, fx: 200, fy: 200, cx: 100, cy: 100)
    let depth = CaptureDepthImage(width: 200, height: 200, valuesM: Array(repeating: 1, count: 40_000),
                                  confidence: Array(repeating: 2, count: 40_000))
    let frame = CaptureDepthFrame(id: "raw", timestampSeconds: 0, mapFromCamera: localPose(), camera: camera, depth: depth)
    let floor = CaptureSurface(id: "floor", kind: "floor", mapFromSurface: localPose(), dimensionsM: [10, 0, 10])
    let source = localCapture(objects: [localObject("chair")], surfaces: [floor], frames: [frame])
    let navigation = try LocalSceneBuilder.make(from: source, includeDepthPoints: false)
    let full = try LocalSceneBuilder.make(from: source)
    #expect(navigation.pointCloud.isEmpty)
    #expect(!full.pointCloud.isEmpty)
    #expect(navigation.objects == full.objects)
    #expect(navigation.surfaces == full.surfaces)
    #expect(source.frames == [frame])
    try navigation.validate(source: source)
}

@Test func localSceneRejectsInvalidCaptureAndOverflowingDerivedGeometry() throws {
    #expect(throws: CaptureValidationError.self) { try LocalSceneBuilder.make(from: localCapture()) }
    var object = localObject("chair")
    object.mapFromObject = [1, 0]
    #expect(throws: CaptureValidationError.self) { try LocalSceneBuilder.make(from: localCapture(objects: [object])) }
    object = localObject("chair")
    object.mapFromObject[12] = .greatestFiniteMagnitude
    object.dimensionsM[0] = .greatestFiniteMagnitude
    #expect(throws: SceneValidationError.self) { try LocalSceneBuilder.make(from: localCapture(objects: [object])) }
}
