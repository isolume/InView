import Foundation
import simd
import Testing
@testable import AccessCore

@Test func namedRoomsDoNotCountAsStepFreeStairsAlternatives() {
    let destination = AccessPoint(kind: .destination, name: "Kitchen", position: [3, 0, 0], source: .manual, confidence: 1)
    let stairs = Footprint(kind: .stairs, center: [0, -1.5], size: [1, 1], yaw: 0)
    let report = AccessibilityReport(map: room([stairs], points: [destination]))
    #expect(report.findings.contains { $0.title == "Stairs with no step-free alternative" && $0.severity == .barrier })
    #expect(!report.findings.contains { $0.title == "Stairs have a step-free alternative" })
    #expect(!report.findings.contains { $0.title == "Kitchen can't be reached" })
}

@Test func namedRoomAccessibilityIsAuditedThroughItsSelectedRoute() {
    let destination = AccessPoint(kind: .destination, name: "Kitchen", position: [3, 0, 0], source: .manual, confidence: 1)
    let unreachable = wall(from: [1, -3], to: [1, 3])
    let report = AccessibilityReport(map: room([unreachable], points: [destination, point(.elevator, -2, 0)]))
    #expect(report.findings.contains { $0.title == "Kitchen can't be reached" && $0.severity == .barrier })
    #expect(!report.findings.contains { $0.title == "Elevator can't be reached" })
}

@Test func aWellLaidOutFloorScoresFull() {
    var ramp = point(.ramp, 2, 1)
    ramp.slopeDegrees = 3.5
    let report = AccessibilityReport(map: room([
        Footprint(floor: [[-4, -3], [4, -3], [4, 3], [-4, 3]], bottom: 0),
        Footprint(kind: .door, center: [-4, 0], size: [1, 0.15], yaw: .pi / 2),
    ], points: [point(.elevator, -2, 1), ramp]))
    #expect(report.score == 100)
    #expect(report.grade == "A")
    #expect(report.findings.allSatisfy { $0.severity == .good })
    #expect(report.summary == "No barriers found in measurements")
}

@Test func flagsNarrowDoorsSteepRampsAndUnreachablePoints() {
    var ramp = point(.ramp, -2, 1)
    ramp.slopeDegrees = 7.2
    // The elevator sits behind a divider whose only door is 70 cm wide. The scan started at the origin, left of it.
    let divider = wall(from: [1.5, -3], to: [1.5, 3])
    let door = Footprint(kind: .door, center: [1.5, 1.5], size: [0.7, 0.15], yaw: .pi / 2)
    let map = room([divider, door], points: [point(.elevator, 3, -1), ramp])
    let report = AccessibilityReport(map: map)
    let barriers = report.findings.filter { $0.severity == .barrier }.map(\.title)
    #expect(barriers.contains("1 door is too narrow"))
    #expect(barriers.contains("Ramp is too steep"))
    #expect(barriers.contains("Elevator can't be reached"))
    #expect(report.score <= 40)
    #expect(report.findings.first?.severity == .barrier)
}

@Test func notesPointsThatNeedStaff() {
    var elevator = point(.elevator, -2, 1)
    elevator.requiresAssistance = true
    let report = AccessibilityReport(map: room(points: [elevator]))
    #expect(report.findings.contains { $0.severity == .warning && $0.title == "Elevator needs staff to operate" })
}

@Test func readsMapsSavedBeforeNewerFields() throws {
    let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"ramp","position":[1,0,2],"source":"manual","confidence":1}"#
    let decoded = try JSONDecoder().decode(AccessPoint.self, from: Data(json.utf8))
    #expect(decoded.name == "Ramp")
    #expect(decoded.slopeDegrees == nil)
    #expect(!decoded.requiresAssistance)
}

@Test func footprintLocalAxesRoundTrip() {
    let table = Footprint(kind: .obstacle, center: [1, -2], size: [1.6, 0.8], yaw: 0.7, furniture: .table)
    let local = SIMD2<Float>(0.5, -0.3)
    #expect(simd_distance(table.local(table.floorPoint(local: local)), local) < 1e-5)
}

@Test func readsFootprintsSavedWithoutFurniture() throws {
    let json = #"{"kind":"obstacle","center":[1,2],"size":[0.5,0.5],"yaw":0}"#
    let decoded = try JSONDecoder().decode(Footprint.self, from: Data(json.utf8))
    #expect(decoded.furniture == nil)
    #expect(decoded.height == nil)
}

@Test func cancellableAccessibilityAuditPreservesSavedFindingsAndScore() throws {
    var ramp = point(.ramp, -2, 1)
    ramp.slopeDegrees = 7.2
    ramp.requiresAssistance = true
    let map = room([
        wall(from: [1.5, -3], to: [1.5, 3]),
        Footprint(kind: .door, center: [1.5, 1.5], size: [0.7, 0.15], yaw: .pi / 2),
        Footprint(kind: .stairs, center: [-3, -2], size: [0.8, 0.8], yaw: 0),
    ], points: [point(.elevator, 3.5, -1), ramp])
    let oldAPI = AccessibilityReport(map: map)
    let cancellable = try AccessibilityReport.make(map: map)
    #expect(cancellable.score == oldAPI.score)
    #expect(cancellable.findings == oldAPI.findings)
    #expect(cancellable.findings.contains { $0.title == "1 door is too narrow" })
    #expect(cancellable.findings.contains { $0.title == "Elevator can't be reached" })
    #expect(cancellable.findings.contains { $0.title == "Ramp needs staff to operate" })
}

@Test func aCancelledAccessibilityAuditDoesNotProduceAReport() async {
    let map = room(points: [point(.elevator, 2, 0)])
    let task = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try AccessibilityReport.make(map: map)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func auditWithoutDestinationsStillChecksDoorsAndStairs() throws {
    let map = room([
        Footprint(kind: .door, center: [4, 0], size: [0.7, 0.15], yaw: .pi / 2),
        Footprint(kind: .stairs, center: [2, 0], size: [1, 1], yaw: 0),
    ], points: [])
    let report = try AccessibilityReport.make(map: map)
    #expect(report.findings.contains { $0.title == "1 door is too narrow" && $0.severity == .barrier })
    #expect(report.findings.contains { $0.title == "Stairs with no step-free alternative" && $0.severity == .barrier })
    #expect(report.findings.contains { $0.title == "No elevator mapped" && $0.severity == .warning })
    #expect(report.score == 39)
}

@Test func aSparseScanPromptsMeasurementsInsteadOfClaimingAccessibility() {
    let map = VenueMap(floorY: 0, footprints: [], points: [])
    let checks = ScanReviewChecks(map: map)
    #expect(checks.items.map(\.id) == [.floorCoverage, .doorwayWidths, .destinations])
    #expect(checks.needsReview)
    #expect(checks.doorwayMeasurementCount == 0)
    #expect(!checks.hasRoutingDestinations)

    let report = AccessibilityReport(map: map)
    #expect(report.summary == "Measurements to review")
    #expect(report.findings.allSatisfy { $0.severity == .warning })
    #expect(report.findings.contains { $0.title == "No doorway widths measured" })
    #expect(report.findings.contains { $0.title == "Floor coverage not captured" })
}

@Test func doorAndOpeningWidthsBothParticipateInTheMeasurementReview() {
    let map = room([
        Footprint(kind: .door, center: [-4, 0], size: [1, 0.15], yaw: .pi / 2),
        Footprint(kind: .opening, center: [4, 0], size: [0.7, 0.15], yaw: .pi / 2),
    ], points: [])
    let checks = ScanReviewChecks(map: map)
    #expect(checks.doorwayMeasurementCount == 2)
    #expect(!checks.items.contains { $0.id == .doorwayWidths })
    let report = AccessibilityReport(map: map)
    #expect(report.findings.contains { $0.title == "1 opening is too narrow" && $0.severity == .barrier })
    #expect(report.findings.contains { $0.title == "Door widths meet the guide" && $0.severity == .good })
}

@Test func invalidDoorwayWidthsAreMissingEvidenceRatherThanPassingOrCrashing() {
    let invalidWidths: [Float] = [0, -0.2, .nan, .infinity, -.infinity]
    let map = VenueMap(floorY: 0, footprints: invalidWidths.map {
        Footprint(kind: .door, center: .zero, size: [$0, 0.15], yaw: 0)
    } + [Footprint(kind: .opening, center: [2, 0], size: [1, 0.15], yaw: 0)], points: [])
    let checks = ScanReviewChecks(map: map)
    #expect(checks.doorwayMeasurementCount == 1)
    #expect(checks.unmeasuredDoorwayCount == invalidWidths.count)
    #expect(checks.items.contains { $0.id == .doorwayWidths })
    let report = AccessibilityReport(map: map)
    #expect(!report.findings.contains { $0.title == "Door widths meet the guide" })
    #expect(report.findings.contains { $0.title == "5 doorway widths need another look" && $0.severity == .warning })
}

@Test func unknownOrInvalidRampSlopesNeverEstablishAStairsAlternative() {
    let invalidSlopes: [Float?] = [nil, -.infinity, .infinity, .nan, -1, 90]
    for slope in invalidSlopes {
        var ramp = point(.ramp, 2, 1)
        ramp.slopeDegrees = slope
        let map = room([Footprint(kind: .stairs, center: [-2, -1], size: [1, 1], yaw: 0)], points: [ramp])
        let checks = ScanReviewChecks(map: map)
        #expect(checks.unmeasuredRampCount == 1)
        #expect(checks.items.contains { $0.id == .rampSlopes })
        let report = AccessibilityReport(map: map)
        #expect(report.findings.contains { $0.title == "Ramp: slope not measured" && $0.severity == .warning })
        #expect(report.findings.contains { $0.title == "Stairs with no step-free alternative" && $0.severity == .barrier })
        #expect(!report.findings.contains { $0.title == "Check the mapped stairs alternative" })
        #expect(!report.findings.contains { $0.severity == .good && $0.title.contains("slope") })
    }
}

@Test func aMeasuredRampStillRequiresCheckingThatItBypassesTheStairs() {
    var ramp = point(.ramp, 2, 1)
    ramp.slopeDegrees = 3
    let map = room([Footprint(kind: .stairs, center: [-2, -1], size: [1, 1], yaw: 0)], points: [ramp])
    let report = AccessibilityReport(map: map)
    #expect(!report.findings.contains { $0.title == "Stairs with no step-free alternative" })
    #expect(report.findings.contains { $0.title == "Check the mapped stairs alternative" && $0.severity == .warning })
}

@Test func scanChecksRequireFloorMeasurementsAtTheCurrentLevel() {
    var map = room([
        Footprint(floor: [[-4, -3], [4, -3], [4, 3], [-4, 3]], bottom: 4),
    ], points: [])
    #expect(ScanReviewChecks(map: map).items.contains { $0.id == .floorCoverage })
    map.footprints.append(Footprint(floor: [[-4, -3], [4, -3], [4, 3], [-4, 3]], bottom: 0))
    #expect(!ScanReviewChecks(map: map).items.contains { $0.id == .floorCoverage })
}

@Test func legacyReportScoresDoNotTurnIntoAccessibilityVerdicts() throws {
    let report = try JSONDecoder().decode(AccessibilityReport.self, from: Data(#"{"score":100,"findings":[]}"#.utf8))
    #expect(report.score == 100)
    #expect(report.summary == "No measurements yet")
}
