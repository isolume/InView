import Foundation
import Testing
@testable import AccessCore

private let polygonSurfacePose: [Float] = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 8, -1.2, 3, 1]
private let concaveLocalFloor: [[Float]] = [
    [-3, -2, 0], [3, -2, 0], [3, 0, 0], [0, 0, 0], [0, 2, 0], [-3, 2, 0],
]

private func polygonSurfaceCapture(_ outline: [[Float]]? = concaveLocalFloor) -> CaptureBundle {
    CaptureBundle(id: "floor-scan", mapID: "building", surfaces: [
        CaptureSurface(id: "measured-floor", kind: "floor", mapFromSurface: polygonSurfacePose,
                       dimensionsM: [6, 4, 0], polygonCorners: outline),
    ])
}

@Test func measuredConcaveSurfaceOutlineSurvivesCaptureAndLocalSceneRoundTrips() throws {
    let capture = polygonSurfaceCapture()
    let captureData = try JSONEncoder().encode(capture)
    let dictionary = try #require(JSONSerialization.jsonObject(with: captureData) as? [String: Any])
    let surfaces = try #require(dictionary["surfaces"] as? [[String: Any]])
    #expect(surfaces[0]["polygon_corners"] as? [[Float]] == concaveLocalFloor)
    #expect(try JSONDecoder().decode(CaptureBundle.self, from: captureData) == capture)

    let scene = try LocalSceneBuilder.make(from: capture, includeDepthPoints: false)
    #expect(scene.surfaces[0].polygonCorners == concaveLocalFloor)
    #expect(scene.surfaces[0].mapFromSurface == polygonSurfacePose)
    #expect(scene.surfaces[0].measuredDimensionsM == [6, 4, 0])
    #expect(scene.surfaces[0].renderDimensionsM == [6, 4, 0.025])
    let sceneData = try JSONEncoder().encode(scene)
    #expect(try JSONDecoder().decode(ProcessedScene.self, from: sceneData) == scene)
    try scene.validate(source: capture)
}

@Test func oldCaptureAndSceneSurfacesDecodeWithoutAnOutline() throws {
    let capture = polygonSurfaceCapture(nil)
    let captureData = try JSONEncoder().encode(capture)
    #expect(!String(decoding: captureData, as: UTF8.self).contains("polygon_corners"))
    let decodedCapture = try JSONDecoder().decode(CaptureBundle.self, from: captureData)
    #expect(decodedCapture.surfaces[0].polygonCorners == nil)
    let scene = try LocalSceneBuilder.make(from: decodedCapture)
    let sceneData = try JSONEncoder().encode(scene)
    #expect(!String(decoding: sceneData, as: UTF8.self).contains("polygon_corners"))
    #expect(try JSONDecoder().decode(ProcessedScene.self, from: sceneData).surfaces[0].polygonCorners == nil)
    try scene.validate(source: decodedCapture)
}

@Test func processedSurfaceMayNotDiscardOrChangeTheMeasuredOutline() throws {
    let capture = polygonSurfaceCapture()
    var scene = try LocalSceneBuilder.make(from: capture)
    scene.surfaces[0].polygonCorners = nil
    #expect(throws: SceneValidationError.self) { try scene.validate(source: capture) }
    scene.surfaces[0].polygonCorners = concaveLocalFloor.reversed()
    // Winding or display simplification cannot change immutable measured geometry.
    #expect(throws: SceneValidationError.self) { try scene.validate(source: capture) }
}

@Test func surfaceOutlinesValidateInEitherNativeFloorPlane() throws {
    try polygonSurfaceCapture().validate()
    let xzFloor = concaveLocalFloor.map { [$0[0], Float(0), $0[1]] }
    try polygonSurfaceCapture(xzFloor).validate()
    try polygonSurfaceCapture(concaveLocalFloor.reversed()).validate()
}

@Test func surfaceOutlinesRejectInvalidShapeAndNonfiniteOrDegenerateGeometry() throws {
    let invalid: [[[Float]]] = [
        [], [[0, 0, 0], [1, 0, 0]], [[0, 0], [1, 0], [0, 1]],
        [[0, 0, 0], [1, 0, 0], [2, 0, 0]],
        [[0, 0, 0], [1, 0, 0], [0, .nan, 0]],
        [[0, 0, 0], [1, 0, 0], [0, .infinity, 0]],
        Array(repeating: [0, 0, 0], count: 129),
    ]
    for outline in invalid {
        #expect(throws: CaptureValidationError.self) { try polygonSurfaceCapture(outline).validate() }
        var scene = try LocalSceneBuilder.make(from: polygonSurfaceCapture(nil))
        scene.surfaces[0].polygonCorners = outline
        #expect(throws: SceneValidationError.self) { try scene.validate() }
    }
}

@Test func surfaceOutlinesAcceptTheVertexLimitAndSmallMeasuredAreas() throws {
    let circle = (0..<128).map { index -> [Float] in
        let angle = Double(index) * 2 * .pi / 128
        return [Float(cos(angle)), Float(sin(angle)), 0]
    }
    try polygonSurfaceCapture(circle).validate()
    try polygonSurfaceCapture([[0, 0, 0], [0.01, 0, 0], [0, 0.01, 0]]).validate()
}
