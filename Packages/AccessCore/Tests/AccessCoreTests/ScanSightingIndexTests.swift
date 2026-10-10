import Foundation
import Testing
@testable import AccessCore

@Test func sightingIndexFindsAcrossCellBoundariesAndNegativeCoordinates() {
    var index = ScanSightingIndex()
    let nearby = UUID(), outside = UUID()
    index.update(nearby, at: [-0.1, 0, -4.1])
    index.update(outside, at: [-3, 0, -7])
    #expect(index.nearby([0.1, 0, -3.9], radius: 0.5, maximumHeightDifference: 1) == [nearby])
}

@Test func sightingIndexMovingAnAnnotationRemovesItsOldCell() {
    var index = ScanSightingIndex()
    let id = UUID()
    index.update(id, at: [0, 0, 0])
    index.update(id, at: [20, 0, 0])
    #expect(index.nearby([0, 0, 0], radius: 1, maximumHeightDifference: 1).isEmpty)
    #expect(index.nearby([20, 0, 0], radius: 1, maximumHeightDifference: 1) == [id])
    index.update(id, at: [20.1, 0, 0])
    #expect(index.nearby([20, 0, 0], radius: 1, maximumHeightDifference: 1) == [id])
}

@Test func sightingIndexKeepsStackedFloorsSeparate() {
    var index = ScanSightingIndex()
    let downstairs = UUID(), upstairs = UUID()
    index.update(downstairs, at: [0, 0, 0])
    index.update(upstairs, at: [0, 3, 0])
    #expect(index.nearby([0, 0, 0], radius: 3, maximumHeightDifference: 1.5) == [downstairs])
    #expect(index.nearby([0, 3, 0], radius: 3, maximumHeightDifference: 1.5) == [upstairs])
}

@Test func sightingIndexRetainsDistantBuildingAnnotationsWithoutReturningThemForEachFrame() {
    var index = ScanSightingIndex()
    let visible = UUID(), distant = UUID()
    index.update(visible, at: [0, 0, 0])
    index.update(distant, at: [1_000, 0, 0])
    for i in 1...10_000 {
        index.update(UUID(), at: [Float(i) * 4, 0, 100])
    }
    #expect(index.nearby([0, 0, 0], radius: 12, maximumHeightDifference: 2) == [visible])
    #expect(index.nearby([1_000, 0, 0], radius: 2, maximumHeightDifference: 2) == [distant])
}

@Test func sightingIndexRejectsNonfiniteCoordinatesAndInvalidQueryBounds() {
    var index = ScanSightingIndex()
    index.update(UUID(), at: [.nan, 0, 0])
    index.update(UUID(), at: [0, .infinity, 0])
    index.update(UUID(), at: [.greatestFiniteMagnitude, 0, 0])
    #expect(index.nearby([0, 0, 0], radius: 12, maximumHeightDifference: 2).isEmpty)
    #expect(index.nearby([0, 0, 0], radius: .infinity, maximumHeightDifference: 2).isEmpty)
    #expect(index.nearby([0, 0, 0], radius: -1, maximumHeightDifference: 2).isEmpty)
    #expect(index.nearby([.nan, 0, 0], radius: 12, maximumHeightDifference: 2).isEmpty)
}
