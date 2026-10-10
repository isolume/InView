import Foundation
import simd
import Testing
@testable import AccessCore

@Test func aWellLaidOutFloorScoresFull() {
    var ramp = point(.ramp, 2, 1)
    ramp.slopeDegrees = 3.5
    let report = AccessibilityReport(map: room(points: [point(.elevator, -2, 1), ramp]))
    #expect(report.score == 100)
    #expect(report.grade == "A")
    #expect(report.findings.allSatisfy { $0.severity == .good })
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
