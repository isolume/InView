import AccessCore
import Foundation
import Testing

private let transitionDoorID = UUID(uuidString: "A10BE000-0000-0000-0000-000000000001")!
private let transitionOpeningID = UUID(uuidString: "A10BE000-0000-0000-0000-000000000002")!

private func transitionPortal(at time: TimeInterval, id: UUID = transitionDoorID,
                              kind: RoomTransitionPortal.Kind = .door,
                              center: SIMD3<Float> = [0, 1.1, 0],
                              axis: SIMD2<Float> = [1, 0], width: Float = 1.2,
                              height: Float = 2.2) -> RoomTransitionPortal {
    RoomTransitionPortal(id: id, kind: kind, center: center, horizontalAxis: axis,
                         width: width, height: height, observedAt: time)
}

private func transitionSample(_ detector: inout RoomTransitionDetector, at time: TimeInterval,
                              z: Float, x: Float = 0, y: Float = 1.5,
                              portal: RoomTransitionPortal? = nil,
                              tracking: Bool = true) -> RoomTransition? {
    detector.update(portals: [portal ?? transitionPortal(at: time)], position: [x, y, z],
                    floorY: 0, timestamp: time, trackingIsNormal: tracking)
}

private func stableApproach(_ detector: inout RoomTransitionDetector, start: TimeInterval = 0,
                            z: Float = -0.9, id: UUID = transitionDoorID,
                            kind: RoomTransitionPortal.Kind = .door) {
    for offset in [0.0, 0.3, 0.6] {
        let result = transitionSample(&detector, at: start + offset, z: z,
                                      portal: transitionPortal(at: start + offset, id: id, kind: kind))
        #expect(result == nil)
    }
}

private func finishCrossing(_ detector: inout RoomTransitionDetector, start: TimeInterval = 0,
                            direction: Float = 1, id: UUID = transitionDoorID,
                            kind: RoomTransitionPortal.Kind = .door) -> RoomTransition? {
    let depths: [Float] = [-0.6, -0.25, 0.15, 0.55, 0.8]
    var results: [RoomTransition] = []
    for (index, depth) in depths.enumerated() {
        let time = start + 0.9 + Double(index) * 0.3
        if let event = transitionSample(&detector, at: time, z: depth * direction,
                                        portal: transitionPortal(at: time, id: id, kind: kind)) {
            results.append(event)
        }
    }
    #expect(results.count <= 1)
    return results.first
}

@Test func largeRoomNeverSplitsForTimeDistanceOrExtent() {
    var detector = RoomTransitionDetector()
    for tick in 0...14_400 {
        let time = Double(tick) * 0.25
        let position = SIMD3<Float>(Float(sin(time / 20)) * 40, 1.5, Float(cos(time / 20)) * 40)
        #expect(detector.update(portals: [], position: position, floorY: 0,
                                timestamp: time, trackingIsNormal: true) == nil)
    }
}

@Test func stableDoorRequiresCrossingAndSustainedClearance() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    let event = finishCrossing(&detector)
    #expect(event?.portalID == transitionDoorID)
    #expect(event?.kind == .door)
    #expect(event?.position.z == 0.8)
    #expect(event?.timestamp == 2.1)
    for tick in 0..<20 {
        #expect(transitionSample(&detector, at: 2.4 + Double(tick) * 0.3, z: 0.8) == nil)
    }
}

@Test func openingCrossingsUseSameConfirmationAsDoors() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector, id: transitionOpeningID, kind: .opening)
    let event = finishCrossing(&detector, id: transitionOpeningID, kind: .opening)
    #expect(event?.portalID == transitionOpeningID)
    #expect(event?.kind == .opening)
}

@Test func repeatedCameraPollsDoNotMakeOneMeasurementStable() {
    var detector = RoomTransitionDetector()
    let portal = transitionPortal(at: 0)
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        #expect(transitionSample(&detector, at: Double(index) * 0.2, z: depth, portal: portal) == nil)
    }
}

@Test func walkingPastOrOutsideDoorwayDoesNotSplit() {
    var detector = RoomTransitionDetector()
    for tick in 0..<20 {
        #expect(transitionSample(&detector, at: Double(tick) * 0.3,
                                 z: -0.9, x: Float(tick) * 0.15 - 1.4) == nil)
    }
    detector.reset()
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        #expect(transitionSample(&detector, at: Double(index) * 0.3, z: depth, x: 1.3) == nil)
    }
}

@Test func doorwayEdgeIsNotTreatedAsPassingThroughOpening() {
    var detector = RoomTransitionDetector()
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        // Inside the approach tolerance, but outside the measured clear passage.
        #expect(transitionSample(&detector, at: Double(index) * 0.3, z: depth, x: 0.59) == nil)
    }
}

@Test func jitterAtPlaneAndBackingOutDoNotSplit() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    for (index, depth) in ([-0.5, -0.1, 0.1, -0.08, 0.04, -0.05, 0.1, -0.3, -0.8] as [Float]).enumerated() {
        #expect(transitionSample(&detector, at: 0.9 + Double(index) * 0.3, z: depth) == nil)
    }
}

@Test func brieflyClearingDoorAndReturningCancelsPendingCrossing() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    for (index, depth) in ([-0.6, -0.2, 0.2, 0.5, 0.25, -0.15, -0.7] as [Float]).enumerated() {
        #expect(transitionSample(&detector, at: 0.9 + Double(index) * 0.2, z: depth) == nil)
    }
}

@Test func PoorTrackingDiscardsStablePortalAndPendingCrossing() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    #expect(transitionSample(&detector, at: 0.9, z: -0.3) == nil)
    #expect(transitionSample(&detector, at: 1.2, z: 0.2) == nil)
    #expect(transitionSample(&detector, at: 1.5, z: 0.5, tracking: false) == nil)
    for tick in 0..<10 {
        #expect(transitionSample(&detector, at: 1.8 + Double(tick) * 0.3, z: 0.8) == nil)
    }
}

@Test func missingOrStalePortalDiscardsPendingCrossing() {
    for stale in [false, true] {
        var detector = RoomTransitionDetector()
        stableApproach(&detector)
        #expect(transitionSample(&detector, at: 0.9, z: -0.3) == nil)
        #expect(transitionSample(&detector, at: 1.2, z: 0.2) == nil)
        let portals = stale ? [transitionPortal(at: -1)] : []
        #expect(detector.update(portals: portals, position: [0, 1.5, 0.5], floorY: 0,
                                timestamp: 1.5, trackingIsNormal: true) == nil)
        for tick in 0..<10 {
            #expect(transitionSample(&detector, at: 1.8 + Double(tick) * 0.3, z: 0.8) == nil)
        }
    }
}

@Test func refinedOrMovingDoorPlaneCannotCrossStationaryCamera() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    for tick in 0..<20 {
        let time = 0.9 + Double(tick) * 0.3
        let center = SIMD3<Float>(0, 1.1, -Float(tick) * 0.15)
        #expect(transitionSample(&detector, at: time, z: -0.9,
                                 portal: transitionPortal(at: time, center: center)) == nil)
    }
}

@Test func tinyDoorsRaisedOpeningsAndInvalidMeasurementsAreRejected() {
    let invalids: [RoomTransitionPortal] = [
        transitionPortal(at: 0, width: 0.4),
        transitionPortal(at: 0, height: 1.2),
        transitionPortal(at: 0, kind: .opening, center: [0, 2.4, 0], height: 2),
        transitionPortal(at: 0, center: [.nan, 1.1, 0]),
        transitionPortal(at: 0, axis: [0, 0]),
        transitionPortal(at: 0, axis: [0.2, 0]),
        transitionPortal(at: 0, width: .infinity),
        transitionPortal(at: 0, height: .nan),
    ]
    for invalid in invalids {
        var detector = RoomTransitionDetector()
        for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
            var portal = invalid; portal.observedAt = Double(index) * 0.3
            #expect(transitionSample(&detector, at: portal.observedAt, z: depth, portal: portal) == nil)
        }
    }
}

@Test func cameraMustPassWithinDoorHeight() {
    var detector = RoomTransitionDetector()
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        #expect(transitionSample(&detector, at: Double(index) * 0.3, z: depth, y: 2.5) == nil)
    }
}

@Test func teleportsFastMotionAndFrameGapsCannotCreateCrossings() {
    for sample in [(0.7, Float(0.8)), (1.8, Float(0.8)), (0.9, Float(1.4))] {
        var detector = RoomTransitionDetector()
        stableApproach(&detector)
        #expect(transitionSample(&detector, at: sample.0, z: sample.1) == nil)
        for tick in 1..<8 {
            #expect(transitionSample(&detector, at: sample.0 + Double(tick) * 0.3, z: sample.1) == nil)
        }
    }
}

@Test func invalidAndOutOfOrderTimestampsDiscardContinuity() {
    for invalid in [Double.nan, Double.infinity, 0.3] {
        var detector = RoomTransitionDetector()
        stableApproach(&detector)
        #expect(transitionSample(&detector, at: 0.9, z: -0.3) == nil)
        #expect(transitionSample(&detector, at: invalid, z: 0.2) == nil)
        for tick in 0..<8 {
            #expect(transitionSample(&detector, at: 1.2 + Double(tick) * 0.3, z: 0.8) == nil)
        }
    }
}

@Test func futurePortalMeasurementsAndRepeatedFrameTimestampsCannotArm() {
    var detector = RoomTransitionDetector()
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        #expect(transitionSample(&detector, at: Double(index) * 0.3, z: depth,
                                 portal: transitionPortal(at: 10 + Double(index) * 0.3)) == nil)
    }
    detector.reset()
    for time in [0.0, 0.0, 0.0, 0.3, 0.3, 0.3] {
        #expect(transitionSample(&detector, at: time, z: -0.9) == nil)
    }
    #expect(transitionSample(&detector, at: 0.6, z: 0.1) == nil)
    #expect(transitionSample(&detector, at: 0.9, z: 0.6) == nil)
    #expect(transitionSample(&detector, at: 1.2, z: 0.8) == nil)
}

@Test func duplicateIDsDoNotProduceAmbiguousCrossings() {
    var detector = RoomTransitionDetector()
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        let time = Double(index) * 0.3
        let portal = transitionPortal(at: time)
        #expect(detector.update(portals: [portal, portal], position: [0, 1.5, depth], floorY: 0,
                                timestamp: time, trackingIsNormal: true) == nil)
    }
}

@Test func handoffPreservesSpatialCooldownEvenWithNewRoomPlanID() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    #expect(finishCrossing(&detector) != nil)
    detector.suspend()
    stableApproach(&detector, start: 2.4, z: 0.9, id: transitionOpeningID, kind: .opening)
    #expect(finishCrossing(&detector, start: 2.4, direction: -1,
                           id: transitionOpeningID, kind: .opening) == nil)
}

@Test func legitimateReverseCrossingWorksAfterHandoffAndCooldown() {
    var detector = RoomTransitionDetector()
    stableApproach(&detector)
    #expect(finishCrossing(&detector) != nil)
    detector.suspend()
    stableApproach(&detector, start: 9, z: 0.9, id: transitionOpeningID, kind: .opening)
    let event = finishCrossing(&detector, start: 9, direction: -1,
                               id: transitionOpeningID, kind: .opening)
    #expect(event?.portalID == transitionOpeningID)
    #expect(event?.position.z == -0.8)
}

@Test func reversedSurfaceAxisDoesNotInventOrLoseDoorCrossing() {
    var detector = RoomTransitionDetector()
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        let time = Double(index) * 0.3
        let axis: SIMD2<Float> = index.isMultiple(of: 2) ? [1, 0] : [-1, 0]
        let event = transitionSample(&detector, at: time, z: depth,
                                      portal: transitionPortal(at: time, axis: axis))
        if index == 7 { #expect(event?.portalID == transitionDoorID) }
        else { #expect(event == nil) }
    }
}

@Test func rotatedPortalUsesMeasuredWidthAndPlaneInSharedCoordinates() {
    var detector = RoomTransitionDetector()
    let axis = SIMD2<Float>(cos(.pi / 3), sin(.pi / 3))
    let normal = SIMD2<Float>(-axis.y, axis.x)
    let center = SIMD3<Float>(20, 4.3, -12)
    for (index, depth) in ([-0.9, -0.9, -0.9, -0.6, -0.25, 0.15, 0.55, 0.8] as [Float]).enumerated() {
        let time = Double(index) * 0.3
        let point = SIMD3<Float>(center.x + normal.x * depth, 4.7, center.z + normal.y * depth)
        let portal = transitionPortal(at: time, center: center, axis: axis)
        let event = detector.update(portals: [portal], position: point, floorY: 3.2,
                                    timestamp: time, trackingIsNormal: true)
        if index == 7 { #expect(event?.portalID == transitionDoorID) }
        else { #expect(event == nil) }
    }
}
