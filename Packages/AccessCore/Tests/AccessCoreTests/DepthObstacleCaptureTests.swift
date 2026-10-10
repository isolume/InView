import Foundation
import simd
import Testing
@testable import AccessCore

private func clutterFrame(width: Int = 128, height: Int = 256,
                          depth: [Float?], confidence: [Int]? = nil) -> CaptureDepthFrame {
    CaptureDepthFrame(id: UUID().uuidString, timestampSeconds: 1,
                      mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                      camera: .init(imageWidth: width, imageHeight: height, fx: 100, fy: 100, cx: 64, cy: 20),
                      depth: .init(width: width, height: height, valuesM: depth,
                                   confidence: confidence ?? Array(repeating: 2, count: depth.count)))
}

private func bagDepth(widthM: Float = 0.12, distance: Float = 2) -> CaptureDepthFrame {
    let width = 128, height = 256
    var depth = [Float?](repeating: nil, count: width * height)
    let half = max(2, Int(widthM * 100 / (2 * distance)))
    let top = Int(20 + 0.7 * 100 / distance)
    let bottom = min(height - 2, Int(20 + 0.92 * 100 / distance))
    for row in top...bottom {
        for column in (64 - half)...(64 + half) { depth[row * width + column] = distance }
    }
    return clutterFrame(depth: depth)
}

private func clutterSample(cell: SIMD2<Int>, floorY: Float = 0,
                           bottom: Float = 0.1, top: Float = 0.3) -> DepthObstacleEvidence.Sample {
    let start = SIMD2(Float(cell.x), Float(cell.y)) * DepthObstacleEvidence.cellSize
    return .init(cell: cell, lower: start + SIMD2(repeating: 0.01),
                 upper: start + SIMD2(repeating: 0.13),
                 bottom: floorY + bottom, top: floorY + top, floorY: floorY, support: 4)
}

@Test func supportedSmallBagSidesBecomeMeasuredGenericBounds() throws {
    for width in [Float(0.12), Float(0.3)] {
        let samples = try DepthObstacleEvidence.samples(from: bagDepth(widthM: width), floorY: -1)
        #expect(!samples.isEmpty)
        var accumulator = DepthObstacleAccumulator()
        accumulator.observe(samples, timestamp: 0)
        #expect(accumulator.snapshot().isEmpty)
        accumulator.observe(samples, timestamp: 1)
        let obstacle = try #require(accumulator.snapshot().first)
        #expect(obstacle.kind == .obstacle)
        #expect(obstacle.furniture == nil)
        #expect(abs(obstacle.size.x - width) <= 0.04)
        #expect(obstacle.size.y == 0.1)
        #expect(try #require(obstacle.bottom) > -0.95)
        #expect(try #require(obstacle.height) >= 0.06)
    }
}

@Test func depthClutterUsesScaledCalibrationAndRotatedTranslatedCameraPose() throws {
    var frame = bagDepth()
    frame.camera = .init(imageWidth: 256, imageHeight: 512, fx: 200, fy: 200, cx: 128, cy: 40)
    frame.mapFromCamera = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 3, 1, 4, 1]
    let samples = try DepthObstacleEvidence.samples(from: frame, floorY: 0)
    var accumulator = DepthObstacleAccumulator()
    accumulator.observe(samples, timestamp: 0)
    accumulator.observe(samples, timestamp: 1)
    let obstacle = try #require(accumulator.snapshot().first)
    #expect(simd_distance(obstacle.center, SIMD2(1, 4)) < 0.03)
    #expect(obstacle.size.x == 0.1)
    #expect(abs(obstacle.size.y - 0.12) <= 0.04)
    #expect(try #require(obstacle.bottom) >= 0.08)
    #expect(try #require(obstacle.height) >= 0.06)
}

@Test func capturedClutterBoundsSurviveSceneExportAndBlockKnownFloorRoutes() throws {
    let samples = try DepthObstacleEvidence.samples(from: bagDepth(widthM: 0.3), floorY: -1)
    var accumulator = DepthObstacleAccumulator()
    accumulator.observe(samples, timestamp: 0)
    accumulator.observe(samples, timestamp: 1)
    var footprint = try #require(accumulator.snapshot().first)
    footprint.yaw = 0.4
    let object = try #require(DepthObstacleEvidence.captureObject(from: footprint, id: "observed-clutter"))
    #expect(object.category == "unclassified_obstacle")
    #expect(object.dimensionsM == [footprint.size.x, try #require(footprint.height), footprint.size.y])
    #expect(abs(object.mapFromObject[13] - ((try #require(footprint.bottom)) + (try #require(footprint.height)) / 2)) < 0.001)
    let capture = CaptureBundle(id: "depth-clutter", mapID: "room", objects: [object])
    let scene = try LocalSceneBuilder.make(from: capture, includeDepthPoints: false)
    let rendered = try #require(scene.objects.first)
    #expect(rendered.modelKey == "bounds_v1")
    #expect(rendered.sourceCategory == "unclassified_obstacle")
    #expect(rendered.measuredDimensionsM == object.dimensionsM)
    #expect(rendered.mapFromObject == object.mapFromObject)
    let floor = Footprint(floor: [[-2, -4], [2, -4], [2, 0], [-2, 0]], bottom: -1)
    let map = VenueMap(floorY: -1, footprints: [floor, footprint], points: [])
    let grid = OccupancyGrid(map: map, clearance: 0.1)
    let atObstacle = try #require(grid.index(containing: footprint.center))
    #expect(grid.isBlocked(atObstacle))
}

@Test func genericClutterExportRejectsMissingOrInvalidMeasurements() {
    var footprint = Footprint(kind: .obstacle, center: [0, 0], size: [0.2, 0.2], yaw: 0,
                              bottom: 0.1, height: 0.2)
    #expect(DepthObstacleEvidence.captureObject(from: footprint, id: "") == nil)
    footprint.height = nil
    #expect(DepthObstacleEvidence.captureObject(from: footprint, id: "clutter") == nil)
    footprint.height = 0.2; footprint.size.x = -.infinity
    #expect(DepthObstacleEvidence.captureObject(from: footprint, id: "clutter") == nil)
}

@Test func flatFloorWithBiasedElevationAndGentleRampAreNotClutter() throws {
    for slope: Float in [0, 0.15] {
        var depth = [Float?](repeating: nil, count: 128 * 256)
        for row in 30..<256 {
            for column in 0..<128 {
                depth[row * 128 + column] = 1 / ((Float(row) - 20) / 100 + slope)
            }
        }
        let samples = try DepthObstacleEvidence.samples(from: clutterFrame(depth: depth), floorY: -1.18)
        #expect(samples.isEmpty)
    }
}

@Test func obstacleTopAloneDoesNotInventAnObjectVolume() throws {
    var depth = [Float?](repeating: nil, count: 128 * 256)
    for row in 50..<100 {
        for column in 50..<78 { depth[row * 128 + column] = 0.7 / ((Float(row) - 20) / 100) }
    }
    #expect(try DepthObstacleEvidence.samples(from: clutterFrame(depth: depth), floorY: -1).isEmpty)
    var accumulator = DepthObstacleAccumulator()
    let flat = clutterSample(cell: [0, 0], bottom: 0.18, top: 0.18)
    accumulator.observe([flat], timestamp: 0)
    accumulator.observe([flat], timestamp: 1)
    #expect(accumulator.snapshot().isEmpty)
}

@Test func ownFeetUnderPhoneAreExcludedButBagAheadIsCaptured() throws {
    // Its range from the camera is more than 0.5m because the phone is above it;
    // horizontal distance, rather than 3D depth alone, identifies the excluded region.
    #expect(try DepthObstacleEvidence.samples(from: bagDepth(widthM: 0.2, distance: 0.6), floorY: -1).isEmpty)
    #expect(!(try DepthObstacleEvidence.samples(from: bagDepth(widthM: 0.2, distance: 1), floorY: -1)).isEmpty)
}

@Test func missingOrLowConfidenceDepthCannotCreateClutter() throws {
    var frame = bagDepth()
    frame.depth.confidence = nil
    #expect(try DepthObstacleEvidence.samples(from: frame, floorY: -1).isEmpty)
    frame.depth.confidence = Array(repeating: 1, count: frame.depth.valuesM.count)
    #expect(try DepthObstacleEvidence.samples(from: frame, floorY: -1).isEmpty)
}

@Test func isolatedAndDiscontinuousDepthReturnsAreRejected() throws {
    var depth = [Float?](repeating: nil, count: 128 * 256)
    depth[60 * 128 + 64] = 2
    #expect(try DepthObstacleEvidence.samples(from: clutterFrame(depth: depth), floorY: -1).isEmpty)
    for row in 50..<70 {
        for column in 50..<78 { depth[row * 128 + column] = (row + column) % 2 == 0 ? 2 : 3 }
    }
    #expect(try DepthObstacleEvidence.samples(from: clutterFrame(depth: depth), floorY: -1).isEmpty)
}

@Test func malformedDepthCalibrationAndArrayShapesThrow() {
    var frame = bagDepth()
    frame.camera.fx = 0
    #expect(throws: CaptureValidationError.self) { try DepthObstacleEvidence.samples(from: frame, floorY: -1) }
    frame = bagDepth(); frame.mapFromCamera[0] = 2
    #expect(throws: CaptureValidationError.self) { try DepthObstacleEvidence.samples(from: frame, floorY: -1) }
    frame = bagDepth(); frame.depth.valuesM.removeLast()
    #expect(throws: CaptureValidationError.self) { try DepthObstacleEvidence.samples(from: frame, floorY: -1) }
    frame = bagDepth(); frame.depth.confidence?.removeLast()
    #expect(throws: CaptureValidationError.self) { try DepthObstacleEvidence.samples(from: frame, floorY: -1) }
    frame = bagDepth(); frame.pixelOrientation = "rotated"
    #expect(throws: CaptureValidationError.self) { try DepthObstacleEvidence.samples(from: frame, floorY: -1) }
}

@Test func repeatedDepthWithinOneFrameOrTooSoonCannotConfirmAnObstacle() {
    let sample = clutterSample(cell: [0, 0])
    var accumulator = DepthObstacleAccumulator()
    accumulator.observe(Array(repeating: sample, count: 30), timestamp: 0)
    accumulator.observe([sample], timestamp: 0)
    accumulator.observe([sample], timestamp: 0.25)
    #expect(accumulator.snapshot().isEmpty)
    accumulator.observe([sample], timestamp: 0.75)
    #expect(accumulator.snapshot().count == 1)
}

@Test func movingOrChangingHeightEvidenceDoesNotConfirmStaticClutter() {
    var moving = DepthObstacleAccumulator()
    moving.observe([clutterSample(cell: [0, 0])], timestamp: 0)
    moving.observe([clutterSample(cell: [4, 0])], timestamp: 1)
    #expect(moving.snapshot().isEmpty)
    var changing = DepthObstacleAccumulator()
    changing.observe([clutterSample(cell: [0, 0], bottom: 0.1, top: 0.3)], timestamp: 0)
    changing.observe([clutterSample(cell: [0, 0], bottom: 0.45, top: 0.65)], timestamp: 1)
    #expect(changing.snapshot().isEmpty)
}

@Test func temporalHeightJitterCannotTurnFlatReturnsIntoAVolume() {
    var accumulator = DepthObstacleAccumulator()
    accumulator.observe([clutterSample(cell: [0, 0], bottom: 0.18, top: 0.18)], timestamp: 0)
    accumulator.observe([clutterSample(cell: [0, 0], bottom: 0.28, top: 0.28)], timestamp: 1)
    #expect(accumulator.snapshot().isEmpty)
}

@Test func confirmedClutterSurvivesRawKeyframeEvictionAndOtherFloorsStaySeparate() {
    let lower = clutterSample(cell: [0, 0])
    let upstairs = clutterSample(cell: [0, 0], floorY: 3)
    var accumulator = DepthObstacleAccumulator()
    accumulator.observe([lower, upstairs], timestamp: 0)
    accumulator.observe([lower, upstairs], timestamp: 1)
    accumulator.observe([], timestamp: 100)
    let obstacles = accumulator.snapshot()
    #expect(obstacles.count == 2)
    #expect(obstacles.compactMap(\.bottom) == [0.1, 3.1])
}

@Test func lowVerticalSpreadAndLargeWallClustersDoNotCreateGenericBoxes() {
    var accumulator = DepthObstacleAccumulator()
    let flatSamples = (0..<4).map { clutterSample(cell: [$0, 0], bottom: 0.15, top: 0.18) }
    accumulator.observe(flatSamples, timestamp: 0)
    accumulator.observe(flatSamples, timestamp: 1)
    #expect(accumulator.snapshot().isEmpty)
    var wallAccumulator = DepthObstacleAccumulator()
    let wall = (0..<20).map { clutterSample(cell: [$0, 0]) }
    wallAccumulator.observe(wall, timestamp: 0)
    wallAccumulator.observe(wall, timestamp: 1)
    #expect(wallAccumulator.snapshot().isEmpty)
}

@Test func depthObstacleCellsClustersAndProcessingHaveFixedBudgets() throws {
    let evidence = (0..<30).map { clutterSample(cell: [$0 * 4, 0]) }
    var accumulator = DepthObstacleAccumulator(maximumCells: 10, maximumClusters: 5)
    accumulator.observe(evidence, timestamp: 0)
    accumulator.observe(evidence, timestamp: 1)
    #expect(accumulator.retainedCellCount == 10)
    #expect(accumulator.snapshot().count == 5)
    var frame = clutterFrame(width: 1_000, height: 1_000,
                             depth: Array(repeating: Float(2), count: 1_000_000))
    frame.camera = .init(imageWidth: 1_000, imageHeight: 1_000, fx: 500, fy: 500, cx: 500, cy: 250)
    let samples = try DepthObstacleEvidence.samples(from: frame, floorY: -1)
    #expect(samples.count <= DepthObstacleEvidence.maximumSamples)
    #expect(samples.reduce(0, { $0 + $1.support }) <= DepthObstacleEvidence.maximumSampledPixels)
}

@Test func staleUnconfirmedClutterDoesNotExhaustStorage() {
    var accumulator = DepthObstacleAccumulator(maximumCells: 2)
    for index in 0..<30 {
        accumulator.observe([clutterSample(cell: [index * 4, 0])], timestamp: Double(index) * 10)
    }
    let final = clutterSample(cell: [0, 0])
    accumulator.observe([final], timestamp: 310)
    accumulator.observe([final], timestamp: 311)
    #expect(accumulator.snapshot().count == 1)
}

@Test func cancelledDepthObstacleWorkDoesNotPublishPartialEvidence() async {
    let frame = bagDepth()
    let gate = AsyncStream<Void>.makeStream()
    let task = Task {
        // The stream returns normally after cancellation, so the helper itself must check
        // the task's cancellation flag before publishing evidence.
        var iterator = gate.stream.makeAsyncIterator()
        _ = await iterator.next()
        return try DepthObstacleEvidence.samples(from: frame, floorY: -1)
    }
    task.cancel()
    gate.continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
}
