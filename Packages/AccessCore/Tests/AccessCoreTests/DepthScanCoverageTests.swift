import Foundation
import simd
import Testing
@testable import AccessCore

private func coverageFrame(width: Int = 11, height: Int = 11, timestamp: TimeInterval = 1,
                           x: Float = 0, depth: Float = 2) -> CaptureDepthFrame {
    CaptureDepthFrame(id: "saved-depth", timestampSeconds: timestamp,
                      mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, 0, 0, 1],
                      camera: .init(imageWidth: width, imageHeight: height, fx: 100, fy: 100,
                                    cx: Float(width / 2), cy: Float(height / 2)),
                      depth: .init(width: width, height: height,
                                   valuesM: Array(repeating: depth, count: width * height),
                                   confidence: Array(repeating: 2, count: width * height)))
}

@Test func coverageOnlyAppearsAfterASavedFrameAndUsesMeasuredSurfaceDistance() {
    var coverage = DepthScanCoverage()
    #expect(coverage.snapshot().isEmpty)
    coverage.recordSavedFrame(coverageFrame())
    let snapshot = coverage.snapshot()
    #expect(!snapshot.isEmpty)
    #expect(snapshot.contains(point: [0, 0, -2]))
    #expect(!snapshot.contains(point: [0, 0, -1])) // A foreground object occludes the saved wall.
    #expect(!snapshot.contains(point: [0, 0, -2.05])) // A nearby parallel surface is distinct.
    #expect(!snapshot.contains(point: [1, 0, -2])) // No inferred extension of the wall.
    #expect(snapshot.capturedAt(point: [0, 0, -2]) == 1)
}

@Test func coverageRevisitsPreserveFirstTimeAndSnapshotsRemainImmutable() {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageFrame(width: 3, height: 3))
    let first = coverage.snapshot()
    coverage.recordSavedFrame(coverageFrame(width: 3, height: 3, timestamp: 2))
    #expect(coverage.snapshot().capturedAt(point: [0, 0, -2]) == 1)
    coverage.recordSavedFrame(coverageFrame(width: 3, height: 3, timestamp: 3, x: 1))
    #expect(first.count == 1)
    #expect(!first.contains(point: [1, 0, -2]))
    #expect(coverage.snapshot().capturedAt(point: [1, 0, -2]) == 3)
}

@Test func coverageNormalsRejectPerpendicularSurfacesAndMalformedQueries() {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageFrame())
    let snapshot = coverage.snapshot()
    #expect(snapshot.contains(point: [0, 0, -2], normal: [0, 0, 2]))
    #expect(!snapshot.contains(point: [0, 0, -2], normal: [0, 0, -1]))
    #expect(!snapshot.contains(point: [0, 0, -2], normal: [1, 0, 0]))
    #expect(!snapshot.contains(point: [0, 0, -2], normal: .zero))
    #expect(!snapshot.contains(point: [.nan, 0, -2]))
    #expect(!snapshot.contains(point: [.infinity, 0, -2]))
    #expect(!snapshot.contains(point: [0, 0, -2], normal: [.infinity, 0, 0]))
}

@Test func coverageProjectsScaledCalibrationAndRotatedTranslatedPose() throws {
    var frame = coverageFrame()
    frame.camera = .init(imageWidth: 22, imageHeight: 22, fx: 200, fy: 200, cx: 10, cy: 10)
    frame.mapFromCamera = [0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 3, 1, 4, 1]
    let center = try #require(DepthScanCoverage.samples(from: frame).first { $0.row == 5 && $0.column == 5 })
    #expect(simd_distance(center.point, SIMD3(1, 1, 4)) < 0.0001)
    #expect(simd_distance(center.normal, SIMD3(1, 0, 0)) < 0.0001)
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(frame)
    #expect(coverage.snapshot().contains(point: [1, 1, 4], normal: [1, 0, 0]))
    #expect(!coverage.snapshot().contains(point: [0, 0, -2]))
}

@Test func coverageSamplesDoNotBridgeMissingConfidenceOrDepthDiscontinuities() {
    var frame = coverageFrame(width: 31, height: 11)
    for row in 0..<11 {
        for column in 10...20 { frame.depth.valuesM[row * 31 + column] = nil }
    }
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(frame)
    #expect(!coverage.snapshot().contains(point: [0, 0, -2]))
    #expect(coverage.snapshot().contains(point: [-0.2, 0, -2]))
    #expect(coverage.snapshot().contains(point: [0.2, 0, -2]))
    #expect(!DepthScanCoverage.samples(from: frame).contains { (9...21).contains($0.column) })

    frame = coverageFrame()
    frame.depth.confidence?[5 * 11 + 5] = 1
    #expect(!DepthScanCoverage.samples(from: frame).contains { abs($0.column - 5) + abs($0.row - 5) <= 1 })
    frame = coverageFrame()
    for row in 0..<11 {
        for column in 0..<11 { frame.depth.valuesM[row * 11 + column] = (row + column) % 2 == 0 ? 2 : 3 }
    }
    #expect(DepthScanCoverage.samples(from: frame).isEmpty)
    frame = coverageFrame()
    frame.depth.valuesM = Array(repeating: nil, count: 121)
    frame.depth.valuesM[60] = 2
    #expect(DepthScanCoverage.samples(from: frame).isEmpty)
}

@Test func coverageInvalidCalibrationPoseOrientationAndShapesFailClosed() {
    var invalid: [CaptureDepthFrame] = []
    var frame = coverageFrame(); frame.camera.fx = 0; invalid.append(frame)
    frame = coverageFrame(); frame.camera.fy = .infinity; invalid.append(frame)
    frame = coverageFrame(); frame.camera.cx = -1; invalid.append(frame)
    frame = coverageFrame(); frame.camera.imageWidth = 12; invalid.append(frame)
    frame = coverageFrame(); frame.camera.imageWidth = .max; invalid.append(frame)
    frame = coverageFrame(); frame.depth.width = .max; invalid.append(frame)
    frame = coverageFrame(); frame.mapFromCamera[0] = 2; invalid.append(frame)
    frame = coverageFrame(); frame.mapFromCamera.removeLast(); invalid.append(frame)
    frame = coverageFrame(); frame.pixelOrientation = "portrait"; invalid.append(frame)
    frame = coverageFrame(); frame.timestampSeconds = -.infinity; invalid.append(frame)
    frame = coverageFrame(); frame.depth.valuesM.removeLast(); invalid.append(frame)
    frame = coverageFrame(); frame.depth.confidence?.removeLast(); invalid.append(frame)
    frame = coverageFrame(); frame.depth.confidence = nil; invalid.append(frame)
    frame = coverageFrame(); frame.depth.confidence = Array(repeating: 1, count: 121); invalid.append(frame)
    frame = coverageFrame(); frame.depth.valuesM = Array(repeating: .nan, count: 121); invalid.append(frame)
    frame = coverageFrame(); frame.depth.valuesM = Array(repeating: 5.1, count: 121); invalid.append(frame)
    for frame in invalid {
        #expect(DepthScanCoverage.samples(from: frame).isEmpty)
        var coverage = DepthScanCoverage()
        coverage.recordSavedFrame(frame)
        #expect(coverage.snapshot().isEmpty)
    }
}

@Test func coverageBinsHandleNegativeCoordinatesAndCrossBoundaryMatching() {
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(coverageFrame(width: 3, height: 3, x: -0.001))
    #expect(coverage.snapshot().contains(point: [0.001, 0, -2]))
    #expect(!coverage.snapshot().contains(point: [0.061, 0, -2]))
}

@Test func coverageStorageEvictsOldBinsDeterministicallyAndKeepsAcceptingNewEvidence() {
    var coverage = DepthScanCoverage(maximumCells: 2)
    for index in 0..<20 {
        coverage.recordSavedFrame(coverageFrame(width: 3, height: 3, timestamp: Double(index), x: Float(index)))
        #expect(coverage.snapshot().count <= 2)
        #expect(coverage.snapshot().sampleCount <= 2 * DepthScanCoverage.maximumSamplesPerCell)
    }
    let snapshot = coverage.snapshot()
    #expect(!snapshot.contains(point: [0, 0, -2]))
    #expect(!snapshot.contains(point: [17, 0, -2]))
    #expect(snapshot.contains(point: [18, 0, -2]))
    #expect(snapshot.contains(point: [19, 0, -2]))
    var disabled = DepthScanCoverage(maximumCells: 0)
    disabled.recordSavedFrame(coverageFrame())
    #expect(disabled.snapshot().isEmpty)
    #expect(DepthScanCoverage(maximumCells: .max).maximumCells == DepthScanCoverage.maximumRetainedCells)
}

@Test func coverageSamplingAndRetainedEvidenceHaveFixedBudgets() {
    let frame = coverageFrame(width: 512, height: 512)
    let samples = DepthScanCoverage.samples(from: frame)
    #expect(samples.count <= DepthScanCoverage.maximumSampledPixels)
    var coverage = DepthScanCoverage(maximumCells: 100)
    coverage.recordSavedFrame(frame)
    #expect(coverage.snapshot().count <= 100)
    #expect(coverage.snapshot().sampleCount <= 100 * DepthScanCoverage.maximumSamplesPerCell)
}

@Test func coverageQueriesFindSupportedSamples() {
    var frame = coverageFrame(width: 256, height: 192)
    frame.camera.fx = 200; frame.camera.fy = 200
    let samples = DepthScanCoverage.samples(from: frame)
    var coverage = DepthScanCoverage()
    coverage.recordSavedFrame(frame)
    let snapshot = coverage.snapshot()
    let matched = samples.reduce(0) { $0 + (snapshot.contains(point: $1.point, normal: $1.normal) ? 1 : 0) }
    #expect(matched == samples.count)
    #expect(samples.count <= DepthScanCoverage.maximumSampledPixels)
}
