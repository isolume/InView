import Foundation
import simd
import Testing
@testable import AccessCore

private func measuredFloor(_ boundary: [SIMD2<Float>] = [[0, 0], [3, 0], [3, 2], [0, 2]],
                           elevation: Float = -1.3,
                           classification: ObservedSurfaceGeometry.Classification = .floor,
                           id: UUID = UUID()) -> ObservedSurfaceGeometry.Plane {
    .init(id: id, boundary: boundary.map { SIMD3($0.x, elevation, $0.y) },
          normal: [0, 1, 0], isHorizontal: true, classification: classification)
}

private func measuredBarrier(bottom: Float = -1.3, height: Float = 1,
                             classification: ObservedSurfaceGeometry.Classification = .unclassified,
                             id: UUID = UUID()) -> ObservedSurfaceGeometry.Plane {
    .init(id: id, boundary: [[0, bottom, 0], [3, bottom, 0], [3, bottom + height, 0], [0, bottom + height, 0]],
          normal: [0, 0, 1], isHorizontal: false, classification: classification)
}

@Test func observedFloorsKeepTheirConcaveMeasuredBoundary() throws {
    let boundary: [SIMD2<Float>] = [[0, 0], [3, 0], [3, 1], [1, 1], [1, 3], [0, 3]]
    let floor = try #require(ObservedSurfaceGeometry.footprint(for: measuredFloor(boundary), floorY: -1.3))
    #expect(floor.kind == .floor)
    #expect(floor.polygon == boundary)
    #expect(floor.height == 0)
    // Its bounding rectangle deliberately is not the covered floor outline.
    #expect(floor.corners.count == 6)
}

@Test func floorFallbackRejectsBalconyVoidAndNonFloorHorizontalPlanes() {
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor(elevation: -4.3), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor(elevation: -0.5), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor(classification: .other), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor(classification: .wall), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor(classification: .unclassified), floorY: -1.3) != nil)
}

@Test func shortMeasuredBarriersKeepActualHeightAndBlockRouting() throws {
    let barrier = try #require(ObservedSurfaceGeometry.footprint(for: measuredBarrier(height: 0.85), floorY: -1.3))
    #expect(barrier.kind == .wall)
    #expect(barrier.kind.blocksWheelchairs)
    #expect(abs(try #require(barrier.height) - 0.85) < 0.001)
    #expect(abs(try #require(barrier.bottom) + 1.3) < 0.001)
    #expect(abs(barrier.size.x - 3) < 0.001)
}

@Test func confirmedObservedFloorCanAnchorLowBarriersWithoutRoomPlan() throws {
    let plane = measuredFloor()
    var observations = ObservedSurfaceAccumulator()
    #expect(observations.floorElevation(near: [1, 0, 1]) == nil)
    observations.observe(plane, floorY: -1.3, timestamp: 0)
    observations.observe(plane, floorY: -1.3, timestamp: 0.75)
    let elevation = try #require(observations.floorElevation(near: [1, 0, 1]))
    let barrier = measuredBarrier()
    observations.observe(barrier, floorY: elevation, timestamp: 1.5)
    observations.observe(barrier, floorY: elevation, timestamp: 2.25)
    #expect(observations.snapshot().contains { $0.kind == .wall && $0.id == barrier.id })
    #expect(observations.snapshot().contains { $0.kind == .floor && $0.id == plane.id })
}

@Test func visibleFloorOnAnotherLevelCannotAnchorBalconyBarriers() {
    let plane = measuredFloor(elevation: -4.3)
    var observations = ObservedSurfaceAccumulator()
    observations.observe(plane, floorY: -4.3, timestamp: 0)
    observations.observe(plane, floorY: -4.3, timestamp: 0.75)
    #expect(observations.floorElevation(near: [1, 0, 1]) == nil)
    #expect(observations.floorElevation(near: [1, -3, 1]) == -4.3)
    #expect(observations.floorElevation(near: [30, -3, 1], within: 12) == nil)
}

@Test func barrierFallbackDoesNotTurnObjectsOrFullHeightWallsIntoRailings() {
    #expect(ObservedSurfaceGeometry.footprint(for: measuredBarrier(height: 2.4), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredBarrier(height: 0.2), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredBarrier(bottom: -0.8), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredBarrier(classification: .other), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredBarrier(classification: .floor), floorY: -1.3) == nil)
}

@Test func unstablePlanesNeedRepeatedIndependentObservations() {
    let plane = measuredFloor()
    var observations = ObservedSurfaceAccumulator()
    observations.observe(plane, floorY: -1.3, timestamp: 0)
    #expect(observations.snapshot().isEmpty)
    observations.observe(plane, floorY: -1.3, timestamp: 0)
    #expect(observations.snapshot().isEmpty)
    observations.observe(plane, floorY: -1.3, timestamp: 0.75)
    #expect(observations.snapshot().count == 1)
}

@Test func refinedPlaneReplacesItsEarlierBoundaryWithoutLayerStacking() {
    let id = UUID()
    let original = measuredFloor(id: id)
    let refined = measuredFloor([[0, 0], [4, 0], [4, 2], [0, 2]], id: id)
    var observations = ObservedSurfaceAccumulator()
    observations.observe(original, floorY: -1.3, timestamp: 0)
    observations.observe(original, floorY: -1.3, timestamp: 0.75)
    observations.observe(refined, floorY: -1.3, timestamp: 1.5)
    #expect(observations.snapshot().count == 1)
    #expect(observations.snapshot().first?.polygon == refined.boundary.map { SIMD2($0.x, $0.z) })
}

@Test func longObservedCorridorKeepsGrowingPastFortyMetersAcrossSections() {
    let id = UUID()
    var observations = ObservedSurfaceAccumulator()
    for (section, length) in [30, 60, 100].enumerated() {
        let plane = measuredFloor([[0, 0], [Float(length), 0], [Float(length), 2], [0, 2]], id: id)
        let start = Double(section) * 2
        observations.observe(plane, floorY: -1.3, timestamp: start)
        observations.observe(plane, floorY: -1.3, timestamp: start + 0.75)
        #expect(observations.snapshot().count == 1)
        #expect(observations.snapshot().first?.size.x == Float(length))
        #expect(observations.snapshot().first?.id == id)
    }
}

@Test func largeOutlineJumpNeedsConfirmationBeforeItExpandsCoverage() {
    let id = UUID()
    var observations = ObservedSurfaceAccumulator()
    let short = measuredFloor(id: id)
    let long = measuredFloor([[0, 0], [100, 0], [100, 2], [0, 2]], id: id)
    observations.observe(short, floorY: -1.3, timestamp: 0)
    observations.observe(short, floorY: -1.3, timestamp: 0.75)
    observations.observe(long, floorY: -1.3, timestamp: 1.5)
    #expect(observations.snapshot().first?.size.x == 3)
    observations.observe(long, floorY: -1.3, timestamp: 2.25)
    #expect(observations.snapshot().first?.size.x == 100)
}

@Test func observedGeometryHasDocumentedFloorAndBarrierExtentLimits() {
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor([[0, 0], [200, 0], [200, 2], [0, 2]]), floorY: -1.3) != nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor([[0, 0], [201, 0], [201, 2], [0, 2]]), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor([[0, 0], [100, 0], [100, 60], [0, 60]]), floorY: -1.3) == nil)
    var barrier = measuredBarrier()
    barrier.boundary[1].x = 41
    barrier.boundary[2].x = 41
    #expect(ObservedSurfaceGeometry.footprint(for: barrier, floorY: -1.3) == nil)
}

@Test func abruptlyMovedPlanesNeedConfirmationAtTheirNewPosition() {
    let id = UUID()
    let original = measuredFloor(id: id)
    let moved = measuredFloor([[20, 0], [23, 0], [23, 2], [20, 2]], id: id)
    var observations = ObservedSurfaceAccumulator()
    observations.observe(original, floorY: -1.3, timestamp: 0)
    observations.observe(original, floorY: -1.3, timestamp: 0.75)
    observations.observe(moved, floorY: -1.3, timestamp: 1.5)
    #expect(observations.snapshot().first?.center == SIMD2<Float>(1.5, 1))
    observations.observe(moved, floorY: -1.3, timestamp: 2.25)
    #expect(observations.snapshot().first?.center == SIMD2<Float>(21.5, 1))
}

@Test func explicitReclassificationRemovesMistakenFloorCoverage() {
    let id = UUID()
    let original = measuredFloor(id: id)
    var observations = ObservedSurfaceAccumulator()
    observations.observe(original, floorY: -1.3, timestamp: 0)
    observations.observe(original, floorY: -1.3, timestamp: 0.75)
    observations.observe(measuredFloor(classification: .other, id: id), floorY: -1.3, timestamp: 1.5)
    #expect(observations.snapshot().isEmpty)
}

@Test func observedFloorMasksStayWithinTheCutawayGeometryBudget() {
    var observations = ObservedSurfaceAccumulator()
    for index in 0..<100 {
        let x = Float(index) * 4
        let plane = measuredFloor([[x, 0], [x + 3, 0], [x + 3, 2], [x, 2]])
        observations.observe(plane, floorY: -1.3, timestamp: Double(index) * 2)
        observations.observe(plane, floorY: -1.3, timestamp: Double(index) * 2 + 0.75)
    }
    #expect(observations.snapshot().count == 64)
    #expect(observations.snapshot().flatMap(\.corners).count <= 1_024)
}

@Test func floorVerticesAreBoundedEvenWithComplexOutlines() {
    var observations = ObservedSurfaceAccumulator()
    for index in 0..<100 {
        let boundary: [SIMD2<Float>] = (0..<64).map {
            let angle = Float($0) * 2 * Float.pi / 64
            return SIMD2(Float(index) * 4 + cos(angle), sin(angle))
        }
        let plane = measuredFloor(boundary)
        observations.observe(plane, floorY: -1.3, timestamp: Double(index) * 2)
        observations.observe(plane, floorY: -1.3, timestamp: Double(index) * 2 + 0.75)
    }
    #expect(observations.snapshot().count == 16)
    #expect(observations.snapshot().flatMap(\.corners).count == 1_024)
}

@Test func barrierRetentionHasASeparateBound() {
    var observations = ObservedSurfaceAccumulator()
    for index in 0..<150 {
        let plane = measuredBarrier()
        observations.observe(plane, floorY: -1.3, timestamp: Double(index) * 2)
        observations.observe(plane, floorY: -1.3, timestamp: Double(index) * 2 + 0.75)
    }
    #expect(observations.snapshot().count == 128)
}

@Test func rejectedOutlinesCannotCreateFloorOrExhaustObservationStorage() {
    var invalid = measuredFloor()
    invalid.boundary[0].x = .nan
    #expect(ObservedSurfaceGeometry.footprint(for: invalid, floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor([[0, 0], [3, 3], [0, 3], [3, 0]]), floorY: -1.3) == nil)
    #expect(ObservedSurfaceGeometry.footprint(for: measuredFloor(Array(repeating: .zero, count: 129)), floorY: -1.3) == nil)
    var observations = ObservedSurfaceAccumulator(maximumPlanes: 2)
    for index in 0..<20 {
        observations.observe(measuredFloor(), floorY: -1.3, timestamp: Double(index) * 5)
    }
    let valid = measuredFloor()
    observations.observe(valid, floorY: -1.3, timestamp: 100)
    observations.observe(valid, floorY: -1.3, timestamp: 100.75)
    #expect(observations.snapshot().count == 1)
}
