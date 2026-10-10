import AccessCore
import Foundation
import Testing

private func establishFloorBaseline(_ detector: inout FloorChangeDetector, elevation: Double = 0) {
    for second in 0...2 {
        let proposal = detector.update(elevationMeters: elevation, timestamp: Double(second))
        #expect(proposal == nil)
    }
    #expect(!detector.isChangingElevation)
}

private func settleFloor(_ detector: inout FloorChangeDetector, elevation: Double,
                         startingAt timestamp: TimeInterval) -> [FloorChangeDetector.Proposal] {
    (0...8).compactMap { step in
        detector.update(elevationMeters: elevation + (step.isMultiple(of: 2) ? 0.03 : -0.03),
                        timestamp: timestamp + Double(step) * 0.5)
    }
}

@Test func floorDetectionIgnoresNormalElevationJitterAndPhoneHeightChanges() {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    for second in 3...90 {
        let elevation = second.isMultiple(of: 2) ? 0.25 : -0.25
        let proposal = detector.update(elevationMeters: elevation, timestamp: Double(second))
        #expect(proposal == nil)
        #expect(!detector.isChangingElevation)
    }
    for second in 91...100 {
        let proposal = detector.update(elevationMeters: 1.3, timestamp: Double(second))
        #expect(proposal == nil)
        #expect(!detector.isChangingElevation)
    }
}

@Test func stairsPauseCurrentFloorBeforeSuggestingTheSettledLanding() throws {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    for step in 1...8 {
        let proposal = detector.update(elevationMeters: Double(step) * 0.4,
                                       timestamp: Double(step + 2))
        #expect(proposal == nil)
        if step < 6 { #expect(!detector.isChangingElevation) }
        if step >= 6 { #expect(detector.isChangingElevation) }
    }
    let proposals = settleFloor(&detector, elevation: 3.2, startingAt: 11)
    let proposal = try #require(proposals.first)
    #expect(proposals.count == 1)
    #expect(proposal.floorDelta == 1)
    #expect(abs(proposal.elevationDeltaMeters - 3.2) < 0.1)
    #expect(proposal.timestamp >= 12.5)
    #expect(detector.isChangingElevation)
}

@Test func elevatorAscentAndDescentUseSignedFloorChanges() throws {
    for direction in [-1.0, 1.0] {
        var detector = FloorChangeDetector()
        establishFloorBaseline(&detector, elevation: 12)
        #expect(detector.update(elevationMeters: 12 + direction * 1.8, timestamp: 3) == nil)
        #expect(!detector.isChangingElevation)
        #expect(detector.update(elevationMeters: 12 + direction * 3.2, timestamp: 4) == nil)
        #expect(detector.update(elevationMeters: 12 + direction * 3.2, timestamp: 4.5) == nil)
        #expect(detector.isChangingElevation)
        let proposals = settleFloor(&detector, elevation: 12 + direction * 3.2, startingAt: 5)
        let proposal = try #require(proposals.first)
        #expect(proposals.count == 1)
        #expect(proposal.floorDelta == Int(direction))
        #expect(abs(proposal.elevationDeltaMeters - direction * 3.2) < 0.1)
    }
}

@Test func elevatorDoesNotSuggestIntermediateFloorsWhileStillMoving() throws {
    var detector = FloorChangeDetector(typicalStoreyHeightMeters: 4)
    establishFloorBaseline(&detector)
    for step in 1...8 {
        let proposal = detector.update(elevationMeters: Double(step), timestamp: Double(step + 2))
        #expect(proposal == nil)
    }
    let proposals = settleFloor(&detector, elevation: 8, startingAt: 11)
    #expect(try #require(proposals.first).floorDelta == 2)
    #expect(proposals.count == 1)
}

@Test func shortElevationSpikesCannotSuggestAFloorOrPauseTheCapture() {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    #expect(detector.update(elevationMeters: 8, timestamp: 3) == nil)
    #expect(detector.update(elevationMeters: 8, timestamp: 3.5) == nil)
    #expect(!detector.isChangingElevation)
    #expect(detector.update(elevationMeters: 0, timestamp: 4) == nil)
    let proposals = settleFloor(&detector, elevation: 0, startingAt: 5)
    #expect(proposals.isEmpty)
    #expect(!detector.isChangingElevation)
}

@Test func returningToTheOriginalFloorClearsTheElevationChange() {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    for second in 3...5 {
        #expect(detector.update(elevationMeters: 1.9, timestamp: Double(second)) == nil)
    }
    #expect(detector.isChangingElevation)
    #expect(detector.update(elevationMeters: 0.7, timestamp: 6) == nil)
    #expect(!detector.isChangingElevation)
    #expect(settleFloor(&detector, elevation: 0, startingAt: 7).isEmpty)
}

@Test func dismissedLandingIsRebasedAndTheNextFloorCanStillBeDetected() throws {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    let firstJourney = settleFloor(&detector, elevation: 3.2, startingAt: 3)
    #expect(try #require(firstJourney.first).floorDelta == 1)
    detector.rebase()
    #expect(!detector.isChangingElevation)
    #expect(settleFloor(&detector, elevation: 3.2, startingAt: 7.5).isEmpty)
    let secondJourney = settleFloor(&detector, elevation: 6.4, startingAt: 12)
    #expect(try #require(secondJourney.first).floorDelta == 1)
    #expect(secondJourney.count == 1)
}

@Test func resetRequiresAFreshBaselineAtTheNewSensorOrigin() throws {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector, elevation: 20)
    #expect(!settleFloor(&detector, elevation: 23.2, startingAt: 3).isEmpty)
    detector.reset()
    #expect(!detector.isChangingElevation)
    establishFloorBaseline(&detector)
    let proposals = settleFloor(&detector, elevation: -3.2, startingAt: 3)
    #expect(try #require(proposals.first).floorDelta == -1)
}

@Test func floorDetectionRejectsNonfiniteDuplicateAndOutOfOrderSamples() throws {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    #expect(detector.update(elevationMeters: .nan, timestamp: 3) == nil)
    #expect(detector.update(elevationMeters: .infinity, timestamp: 3) == nil)
    #expect(detector.update(elevationMeters: 10, timestamp: .nan) == nil)
    #expect(detector.update(elevationMeters: 10, timestamp: .infinity) == nil)
    #expect(detector.update(elevationMeters: 10, timestamp: 2) == nil)
    #expect(detector.update(elevationMeters: 10, timestamp: 1) == nil)
    #expect(!detector.isChangingElevation)
    let proposals = settleFloor(&detector, elevation: 3.2, startingAt: 3)
    #expect(try #require(proposals.first).floorDelta == 1)
}

@Test func longSensorGapDiscardsTheOldBaselineAndPendingTravel() throws {
    var detector = FloorChangeDetector()
    establishFloorBaseline(&detector)
    #expect(detector.update(elevationMeters: 1.8, timestamp: 3) == nil)
    #expect(detector.update(elevationMeters: 2, timestamp: 5) == nil)
    #expect(detector.isChangingElevation)
    #expect(detector.update(elevationMeters: 12, timestamp: 20) == nil)
    #expect(!detector.isChangingElevation)
    #expect(settleFloor(&detector, elevation: 12, startingAt: 21).isEmpty)
    let proposals = settleFloor(&detector, elevation: 15.2, startingAt: 26)
    #expect(try #require(proposals.first).floorDelta == 1)
}
