import AccessCore
import XCTest
@testable import InView

@MainActor
final class FeatureDetectionTests: XCTestCase {
    private func sighting(_ kind: VisionDetection.Kind) -> AccessibilityDetector.Sighting {
        AccessibilityDetector.Sighting(kind: kind, name: "Test", position: .zero, facing: SIMD2(0, -1),
                                        confidence: 1, isManual: false)
    }

    func testOneConfidentElevatorFrameIsNotEnough() {
        var elevator = sighting(.elevator)
        elevator.verifiedFrames = 1
        XCTAssertFalse(elevator.isConfirmed)
        elevator.frames = 2
        XCTAssertTrue(elevator.isConfirmed)
    }

    func testRepeatedUnmeasuredClaimsNeverBecomeConfirmed() {
        for kind in VisionDetection.Kind.allCases {
            var candidate = sighting(kind)
            candidate.frames = 30
            XCTAssertFalse(candidate.isConfirmed)
            candidate.isManual = true
            XCTAssertTrue(candidate.isConfirmed)
        }
    }

    func testRejectsInvalidModelCoordinatesAndBounds() {
        XCTAssertNil(VisionDetection.visibleBounds([0, 0, 2, 1]))
        XCTAssertNil(VisionDetection.visibleBounds([0, 0, .nan, 1]))
        XCTAssertNil(VisionDetection.visibleBounds([0, 0, 0]))
        XCTAssertNotNil(VisionDetection.visibleBounds([0.1, 0.2, 0.3, 0.4]))
        let detection = VisionDetection(kind: .elevator, name: "Bad point", confidence: 1,
                                         target: CGPoint(x: -1, y: 0.5), surface: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(detection.isValid)
    }

    func testMeasuredStairsExportVisibleExtentAndElevation() throws {
        var samples: [SIMD3<Float>] = []
        for step in 0..<4 {
            for x in [Float(-0.5), 0.5] {
                for offset in [Float(0), 0.15] {
                    samples.append(SIMD3(x, Float(step) * 0.17, -2 - Float(step) * 0.28 - offset))
                }
            }
        }
        var candidate = sighting(.stairs)
        candidate.measuredStairs = try XCTUnwrap(StairsCheck.assess(samples, viewer: SIMD3(0, 1.4, 0)).measurement)
        let footprint = try XCTUnwrap(AccessibilityDetector.stairsFootprint(for: candidate))
        XCTAssertEqual(footprint.size.x, 1, accuracy: 0.001)
        XCTAssertEqual(footprint.size.y, 0.99, accuracy: 0.001)
        XCTAssertEqual(footprint.bottom, 0)
        XCTAssertEqual(try XCTUnwrap(footprint.height), 0.51, accuracy: 0.001)
        XCTAssertEqual(footprint.id, candidate.id)
    }
}
