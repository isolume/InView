import Foundation
import simd
import Testing
@testable import AccessCore

@Test func scanPreviewQueryWorkDoesNotGrowWithDistantRoomComponents() {
    var index = ScanPreviewIndex()
    let nearby = ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [0, 0, 0], end: [2, 0, 0])])
    index.replace(with: [nearby])
    let before = index.nearbyQuery(to: [0, 0, 0])
    let distant = (1...10_000).map { value -> ScanPreviewComponent in
        let x = Float(value) * 4
        return ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [x, 0, 100], end: [x + 1, 0, 100])])
    }
    index.replace(with: [nearby] + distant)
    let after = index.nearbyQuery(to: [0, 0, 0])
    #expect(after.lines == before.lines)
    #expect(after.examinedPieceCount == before.examinedPieceCount)
    #expect(after.examinedPieceCount == 1)
}

@Test func scanPreviewRestoresOutlinesWhenRevisitingAnEarlierLocation() {
    var index = ScanPreviewIndex()
    let first = ScanPreviewLine(start: [0, 0, 0], end: [2, 0, 0])
    let next = ScanPreviewLine(start: [100, 0, 0], end: [102, 0, 0])
    index.replace(with: [ScanPreviewComponent(id: UUID(), lines: [first]), ScanPreviewComponent(id: UUID(), lines: [next])])
    #expect(index.nearbyLines(to: [0, 0, 0]) == [first])
    #expect(index.nearbyLines(to: [100, 0, 0]) == [next])
    #expect(index.nearbyLines(to: [0, 0, 0]) == [first])
    #expect(index.nearbyLines(to: [50, 0, 0]).isEmpty)
}

@Test func scanPreviewLatestMeasurementsRemoveAndRefineOldOutlines() {
    var index = ScanPreviewIndex()
    let changingID = UUID(), removedID = UUID()
    let original = ScanPreviewLine(start: [0, 0, 0], end: [2, 0, 0])
    let refined = ScanPreviewLine(start: [100, 0, 0], end: [102, 0, 0])
    index.replace(with: [ScanPreviewComponent(id: changingID, lines: [original]),
                         ScanPreviewComponent(id: removedID, lines: [original])])
    #expect(index.nearbyLines(to: [0, 0, 0]).count == 2)
    index.replace(with: [ScanPreviewComponent(id: changingID, lines: [refined])])
    #expect(index.nearbyLines(to: [0, 0, 0]).isEmpty)
    #expect(index.nearbyLines(to: [100, 0, 0]) == [refined])
    index.replace(with: [])
    #expect(index.nearbyQuery(to: [100, 0, 0]).examinedPieceCount == 0)
}

@Test func scanPreviewLongWallIsFoundNearItsEndpointDespiteADistantCenter() {
    var index = ScanPreviewIndex()
    index.replace(with: [ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [0, 0, 0], end: [200, 0, 0])])])
    let beginning = index.nearbyQuery(to: [0, 0, 0])
    #expect(beginning.lines.count == 2)
    #expect(beginning.examinedPieceCount < 5)
    #expect(beginning.lines.contains { $0.start == [0, 0, 0] })
    #expect(beginning.lines.contains { $0.end == [6, 0, 0] })
    let end = index.nearbyLines(to: [200, 0, 0])
    #expect(end.contains { $0.end == [200, 0, 0] })
    #expect(end.contains { $0.start == [194, 0, 0] })
}

@Test func scanPreviewClipsCrossingLinesToAThreeDimensionalCameraSphere() {
    var index = ScanPreviewIndex()
    let camera = SIMD3<Float>(10, 2, -8)
    let crossing = ScanPreviewLine(start: camera + [-20, -20, -20], end: camera + [20, 20, 20])
    let upstairs = ScanPreviewLine(start: camera + [0, 7, 0], end: camera + [1, 7, 0])
    index.replace(with: [ScanPreviewComponent(id: UUID(), lines: [crossing, upstairs])])
    let result = index.nearbyLines(to: camera)
    #expect(!result.isEmpty)
    for line in result {
        #expect(simd_distance(camera, line.start) <= ScanPreviewIndex.previewRadius + 0.00001)
        #expect(simd_distance(camera, line.end) <= ScanPreviewIndex.previewRadius + 0.00001)
    }
    let greatestDistance = result.flatMap { [simd_distance(camera, $0.start), simd_distance(camera, $0.end)] }.max()!
    #expect(abs(greatestDistance - ScanPreviewIndex.previewRadius) < 0.00001)
}

@Test func scanPreviewExtentIndexHandlesNegativeCellsWithoutDuplicateLines() {
    var index = ScanPreviewIndex()
    index.replace(with: [ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [-4, -0.5, -4], end: [0, -0.5, 0])])])
    let result = index.nearbyQuery(to: [-1, 0, -1])
    #expect(result.lines.count == 2)
    #expect(result.examinedPieceCount == 2)
    #expect(Set(result.lines.map { "\($0.start)-\($0.end)" }).count == 2)
}

@Test func scanPreviewDenseRoomReturnsOnlyTheClosestBoundedSet() {
    var index = ScanPreviewIndex()
    let dense = (0..<2_000).map { value -> ScanPreviewComponent in
        let x = Float(value) * 0.002
        return ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [x, 0, 1], end: [x, 0.1, 1])])
    }
    index.replace(with: dense)
    let result = index.nearbyLines(to: [0, 0, 0])
    #expect(result.count == ScanPreviewIndex.maximumVisibleLines)
    #expect(result.first?.start.x == 0)
    #expect(result.last?.start.x == Float(ScanPreviewIndex.maximumVisibleLines - 1) * 0.002)
    #expect(result.map(\.start.x) == result.map(\.start.x).sorted())
}

@Test func scanPreviewRejectsInvalidCoordinatesAndOversizedComponentsWithoutKeepingOldGeometry() {
    var index = ScanPreviewIndex()
    let id = UUID()
    let good = ScanPreviewLine(start: [0, 0, 0], end: [1, 0, 0])
    index.replace(with: [ScanPreviewComponent(id: id, lines: [good])])
    index.replace(with: [ScanPreviewComponent(id: id, lines: [good, ScanPreviewLine(start: [.nan, 0, 0], end: [1, 0, 0])])])
    #expect(index.nearbyLines(to: [0, 0, 0]).isEmpty)
    index.replace(with: [
        ScanPreviewComponent(id: UUID(), lines: Array(repeating: good, count: ScanPreviewIndex.maximumSegmentsPerComponent + 1)),
        ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [0, 0, 0], end: [2_052, 0, 0])]),
        ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [0, .infinity, 0], end: [1, 0, 0])]),
        ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [.greatestFiniteMagnitude, 0, 0], end: [1, 0, 0])]),
        ScanPreviewComponent(id: UUID(), lines: [ScanPreviewLine(start: [0, 0, 0], end: [0, 0, 0])]),
    ])
    #expect(index.nearbyQuery(to: [0, 0, 0]).examinedPieceCount == 0)
    #expect(index.nearbyLines(to: [.nan, 0, 0]).isEmpty)
    #expect(index.nearbyLines(to: [0, .infinity, 0]).isEmpty)
    #expect(index.nearbyLines(to: [.greatestFiniteMagnitude, 0, 0]).isEmpty)
}

@Test func scanPreviewRepeatedComponentIdentifierUsesTheFinalMeasurement() {
    var index = ScanPreviewIndex()
    let id = UUID()
    let first = ScanPreviewLine(start: [0, 0, 0], end: [1, 0, 0])
    let last = ScanPreviewLine(start: [2, 0, 0], end: [3, 0, 0])
    index.replace(with: [ScanPreviewComponent(id: id, lines: [first]), ScanPreviewComponent(id: id, lines: [last])])
    #expect(index.nearbyLines(to: [0, 0, 0]) == [last])
    index.replace(with: [ScanPreviewComponent(id: id, lines: [last])])
    #expect(index.nearbyQuery(to: [0, 0, 0]).examinedPieceCount == 1)
}
