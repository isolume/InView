import Foundation
import simd
import Testing
@testable import AccessCore

private func walkTrace(_ segments: [[SIMD3<Float>]]) throws -> ScanWalkTrace {
    var samples: [ScanWalkTrace.Sample] = []
    for segment in segments {
        for (index, position) in segment.enumerated() {
            samples.append(.init(cameraPosition: position, timestampSeconds: Double(samples.count), startsSegment: index == 0))
        }
    }
    return try ScanWalkTrace(samples: samples)
}

private func walkFloor(_ x: ClosedRange<Float>, _ z: ClosedRange<Float>, y: Float = -1.3) -> Footprint {
    Footprint(floor: [[x.lowerBound, z.lowerBound], [x.upperBound, z.lowerBound],
                     [x.upperBound, z.upperBound], [x.lowerBound, z.upperBound]], bottom: y)
}

private func walkMap(_ floors: [Footprint], floorY: Float = -1.3) -> VenueMap {
    VenueMap(floorY: floorY, footprints: floors, points: [])
}

@Test func scanWalkTraceDecimatesStraightWalkAndKeepsCurrentEndpoint() {
    var recorder = ScanWalkTraceRecorder()
    for index in 0...100 {
        recorder.record(cameraPosition: [Float(index) * 0.01, 0, 0], timestampSeconds: Double(index) / 60,
                        trackingIsNormal: true, frameIsFresh: true)
    }
    let trace = recorder.trace
    #expect((4...6).contains(trace.samples.count))
    #expect(trace.samples.last?.cameraPosition.x == 1)
    #expect(abs(trace.distanceMeters - 1) < 0.001)
    #expect(abs(trace.durationSeconds - 100 / 60.0) < 0.001)
    #expect(!trace.isTruncated)
    #expect(trace.segments.count == 1)
}

@Test func scanWalkTraceKeepsShortCornerBeforeSpacingThreshold() {
    var recorder = ScanWalkTraceRecorder()
    let points: [SIMD3<Float>] = [[0, 0, 0], [0.1, 0, 0], [0.2, 0, 0], [0.2, 0, 0.1], [0.2, 0, 0.2]]
    for (index, point) in points.enumerated() {
        recorder.record(cameraPosition: point, timestampSeconds: Double(index) * 0.1,
                        trackingIsNormal: true, frameIsFresh: true)
    }
    #expect(recorder.trace.samples.contains { $0.cameraPosition == [0.2, 0, 0] })
    #expect(abs(recorder.trace.distanceMeters - 0.4) < 0.001)
}

@Test func scanWalkTraceBreaksAtLimitedStaleSuspendedAndDiscontinuousPoses() {
    var recorder = ScanWalkTraceRecorder()
    func record(_ point: SIMD3<Float>, _ time: Double, normal: Bool = true, fresh: Bool = true) {
        recorder.record(cameraPosition: point, timestampSeconds: time, trackingIsNormal: normal, frameIsFresh: fresh)
    }
    record([0, 0, 0], 0)
    record([0.1, 0, 0], 0.1)
    record([0.2, 0, 0], 0.2, normal: false)
    record([1, 0, 0], 0.3)
    record([1.1, 0, 0], 0.4, fresh: false)
    record([2, 0, 0], 0.5)
    recorder.suspend()
    record([3, 0, 0], 0.6)
    record([3.1, 0, 0], 3) // Long timestamp gap.
    record([20, 0, 0], 3.1) // Pose jump.
    record([20.5, 0, 0], 3.11) // Impossible short-interval velocity.
    #expect(recorder.trace.segments.count == 7)
    #expect(abs(recorder.trace.distanceMeters - 0.1) < 0.001)
    #expect(abs(recorder.trace.durationSeconds - 0.1) < 0.001)
    #expect(!recorder.trace.samples.contains { $0.timestampSeconds == 0.2 || $0.timestampSeconds == 0.4 })
}

@Test func scanWalkTraceRejectsNonfiniteAndOutOfOrderObservations() throws {
    var recorder = ScanWalkTraceRecorder()
    recorder.record(cameraPosition: .zero, timestampSeconds: 1, trackingIsNormal: true, frameIsFresh: true)
    let duplicate = recorder.record(cameraPosition: [0.1, 0, 0], timestampSeconds: 1, trackingIsNormal: true, frameIsFresh: true)
    let invalidPosition = recorder.record(cameraPosition: [.nan, 0, 0], timestampSeconds: 2, trackingIsNormal: true, frameIsFresh: true)
    let invalidTime = recorder.record(cameraPosition: .zero, timestampSeconds: .infinity, trackingIsNormal: true, frameIsFresh: true)
    #expect(!duplicate && !invalidPosition && !invalidTime)
    recorder.record(cameraPosition: [0.2, 0, 0], timestampSeconds: 3, trackingIsNormal: true, frameIsFresh: true)
    #expect(recorder.trace.segments.count == 2)
    #expect(recorder.trace.distanceMeters == 0)
    #expect(throws: ScanWalkTrace.ValidationError.self) {
        try ScanWalkTrace(samples: [.init(cameraPosition: [.nan, 0, 0], timestampSeconds: 0, startsSegment: true)])
    }
    #expect(throws: ScanWalkTrace.ValidationError.self) {
        try ScanWalkTrace(samples: [.init(cameraPosition: .zero, timestampSeconds: 0, startsSegment: false)])
    }
}

@Test func scanWalkTraceHardCapStopsWithoutBridgingOrDeletingEarlierCorners() throws {
    var recorder = ScanWalkTraceRecorder()
    for index in 0..<5_000 {
        recorder.record(cameraPosition: [Float(index) * 0.25, 0, 0], timestampSeconds: Double(index) * 0.1,
                        trackingIsNormal: true, frameIsFresh: true)
    }
    recorder.suspend()
    #expect(recorder.trace.samples.count == ScanWalkTrace.maximumSamples)
    #expect(recorder.trace.isTruncated)
    #expect(recorder.trace.samples.first?.cameraPosition == .zero)
    #expect(recorder.trace.segments.count == 1)
    let data = try JSONEncoder().encode(recorder.trace)
    #expect(try JSONDecoder().decode(ScanWalkTrace.self, from: data) == recorder.trace)
}

@Test func scanWalkTraceCodablePreservesBreaksAndRejectsOversizedOrInvalidArchives() throws {
    let trace = try walkTrace([[[0, 0, 0], [1, 0, 0]], [[20, 0, 20], [21, 0, 20]]])
    #expect(try JSONDecoder().decode(ScanWalkTrace.self, from: JSONEncoder().encode(trace)) == trace)
    let sample = #"{"cameraPosition":[0,0,0],"timestampSeconds":0,"startsSegment":true}"#
    let large = #"{"samples":["# + Array(repeating: sample, count: 4_097).joined(separator: ",") + "]}"
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ScanWalkTrace.self, from: Data(large.utf8)) }
    let invalid = #"{"samples":[{"cameraPosition":[0,0,0],"timestampSeconds":-1,"startsSegment":true}]}"#
    #expect(throws: (any Error).self) { try JSONDecoder().decode(ScanWalkTrace.self, from: Data(invalid.utf8)) }
}

@Test func scanWalkFloorCoverageRespectsRotatedFloorsAndSmallBoundaryTolerance() throws {
    let floor = Footprint(kind: .floor, center: [2, 3], size: [4, 1], yaw: .pi / 4, bottom: -1.3)
    func position(_ local: SIMD2<Float>) -> SIMD3<Float> {
        let point = floor.floorPoint(local: local)
        return [point.x, 0, point.y]
    }
    let inside = try walkTrace([[position([-1.5, 0]), position([1.5, 0])], [position([0, 0.6])]])
    #expect(!ScanWalkFloorCoverage.assess(trace: inside, map: walkMap([floor])).hasMissingCoverage)
    let outside = try walkTrace([[position([0, 0.8])]])
    let result = ScanWalkFloorCoverage.assess(trace: outside, map: walkMap([floor]))
    #expect(result.hasMissingCoverage)
    #expect(result.missingSegments[0][0].y == -1.3)
    #expect(result.message == "Floor coverage missing along recorded walk")
}

@Test func scanWalkFloorCoverageFindsConcaveNotchBetweenCoveredEndpoints() throws {
    let floor = Footprint(floor: [[0, 0], [4, 0], [4, 1], [1, 1], [1, 4], [0, 4]], bottom: -1.3)
    let trace = try walkTrace([[[0.5, 0, 3], [3, 0, 0.5]]])
    let result = ScanWalkFloorCoverage.assess(trace: trace, map: walkMap([floor]))
    #expect(result.hasMissingCoverage)
    #expect(result.evaluatedPointCount > trace.samples.count)
    #expect(result.missingSegments.flatMap { $0 }.contains { $0.x > 1.15 && $0.z > 1.15 })
    #expect(!result.isLimited)
}

@Test func scanWalkFloorCoverageFindsDisconnectedGapWithoutBridgingSeparateRuns() throws {
    let map = walkMap([walkFloor(0...2, 0...2), walkFloor(3...5, 0...2)])
    let connected = try walkTrace([[[1, 0, 1], [4, 0, 1]]])
    #expect(ScanWalkFloorCoverage.assess(trace: connected, map: map).hasMissingCoverage)
    let separate = try walkTrace([[[1, 0, 1]], [[4, 0, 1]]])
    let result = ScanWalkFloorCoverage.assess(trace: separate, map: map)
    #expect(!result.hasMissingCoverage)
    #expect(result.evaluatedPointCount == 2)
}

@Test func scanWalkFloorCoverageUsesMeasuredUnionAndIgnoresOtherFloorAndMalformedGeometry() throws {
    var obstacle = walkFloor(0...8, 0...8)
    obstacle.kind = .obstacle
    var crossed = walkFloor(0...8, 0...8)
    crossed.polygon = [[0, 0], [8, 8], [0, 8], [8, 0]]
    var invalid = walkFloor(0...8, 0...8)
    invalid.polygon = [[0, 0], [.nan, 8], [0, 8]]
    let map = walkMap([walkFloor(0...2, 0...2), walkFloor(1...4, 0...2),
                       walkFloor(0...8, 0...8, y: 2), obstacle, crossed, invalid])
    let trace = try walkTrace([[[0.5, 0, 1], [3.5, 0, 1]], [[6, 0, 6]]])
    let result = ScanWalkFloorCoverage.assess(trace: trace, map: map)
    #expect(result.measuredFloorCount == 2)
    #expect(result.missingSegments == [[[6, -1.3, 6]]])
    #expect(!result.isLimited)
}

@Test func scanWalkFloorCoverageReportsMissingFloorWithoutCreatingAnyGeometry() throws {
    let trace = try walkTrace([[[0, 0, 0], [1, 0, 0]], [[4, 0, 0]]])
    let map = walkMap([])
    let result = ScanWalkFloorCoverage.assess(trace: trace, map: map)
    #expect(result.measuredFloorCount == 0)
    #expect(result.missingSegments.count == 2)
    #expect(result.hasMissingCoverage)
    #expect(map.footprints.isEmpty)
}

@Test func scanWalkFloorCoverageBudgetsSamplingAndDoesNotPretendUnexaminedFloorIsMissing() throws {
    let trace = try walkTrace([[[0, 0, 0], [100_000, 0, 0]]])
    let sampled = ScanWalkFloorCoverage.assess(trace: trace, map: walkMap([]))
    #expect(sampled.evaluatedPointCount == ScanWalkFloorCoverage.maximumEvaluatedPoints)
    #expect(sampled.isLimited)
    #expect((sampled.missingSegments.last?.last?.x ?? 0) < 3_300)
    let overBudget = walkMap(Array(repeating: walkFloor(0...2, 0...2), count: ScanWalkFloorCoverage.maximumFootprints + 1))
    let result = ScanWalkFloorCoverage.assess(trace: trace, map: overBudget)
    #expect(result.isLimited)
    #expect(!result.hasMissingCoverage)
    #expect(result.evaluatedPointCount == 0)
}

@Test func scanWalkFloorCoverageHandlesEmptyAndInvalidFloorAndPropagatesTruncation() throws {
    let empty = try ScanWalkTrace()
    #expect(ScanWalkFloorCoverage.assess(trace: empty, map: walkMap([])).message == nil)
    let invalid = ScanWalkFloorCoverage.assess(trace: empty, map: walkMap([], floorY: .nan))
    #expect(invalid.isLimited)
    let capped = try ScanWalkTrace(samples: [], isTruncated: true)
    #expect(ScanWalkFloorCoverage.assess(trace: capped, map: walkMap([])).isLimited)
}
