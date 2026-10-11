import Foundation
import Testing
import simd
@testable import AccessCore

struct FeatureDepthGeometryTests {
    @Test func confirmationRequiresIndependentViewNotDuplicateClaims() {
        func independent(_ position: SIMD3<Float>, time: Double, direction: SIMD3<Float> = SIMD3(0, 0, -1)) -> Bool {
            FeatureConfirmation.isNewView(position: position, direction: direction, timestamp: time,
                previousPosition: .zero, previousDirection: SIMD3(0, 0, -1), previousTimestamp: 10)
        }
        #expect(!independent(.zero, time: 12))
        #expect(!independent(SIMD3(0.2, 0, 0), time: 10))
        #expect(!independent(SIMD3(0.04, 0, 0), time: 12))
        #expect(independent(SIMD3(0.2, 0, 0), time: 12))
        #expect(independent(.zero, time: 12, direction: SIMD3(0.3, 0, -0.954)))
        #expect(!independent(SIMD3(.nan, 0, 0), time: 12))
    }

    private func frame() -> CaptureDepthFrame {
        CaptureDepthFrame(id: "sample", timestampSeconds: 1,
            mapFromCamera: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 10, 2, 20, 1],
            camera: CaptureCameraCalibration(imageWidth: 100, imageHeight: 100, fx: 100, fy: 100, cx: 50, cy: 50),
            depth: CaptureDepthImage(width: 10, height: 10, valuesM: Array(repeating: 2, count: 100),
                                     confidence: Array(repeating: 2, count: 100)))
    }

    @Test func usesCapturedPoseAndDepthNotTheCurrentCamera() throws {
        var captured = frame()
        captured.depth = CaptureDepthImage(width: 100, height: 100, valuesM: Array(repeating: 2, count: 10_000),
                                          confidence: Array(repeating: 2, count: 10_000))
        let geometry = try #require(FeatureDepthGeometry(captured))
        #expect(geometry.target(at: SIMD2(0.5, 0.5)) == SIMD3<Float>(10, 2, 18))
        #expect(geometry.point(at: SIMD2(0.5, 0.25)) == SIMD3<Float>(10, 2.5, 18))
    }

    @Test func rejectsUncalibratedLowConfidenceAndOutOfRangePoints() throws {
        var bad = frame(); bad.camera.fx = 0
        #expect(FeatureDepthGeometry(bad) == nil)
        bad = frame(); bad.depth.confidence = nil
        #expect(FeatureDepthGeometry(bad) == nil)
        bad = frame(); bad.depth.confidence = Array(repeating: 0, count: 100)
        let geometry = try #require(FeatureDepthGeometry(bad))
        #expect(geometry.target(at: SIMD2(0.5, 0.5)) == nil)
        let valid = try #require(FeatureDepthGeometry(frame()))
        #expect(valid.point(at: SIMD2(.nan, 0.5)) == nil)
        #expect(valid.point(at: SIMD2(1, 0.5)) == nil)
        #expect(valid.samples(portraitBox: SIMD4(-0.1, 0, 0.4, 0.5)).isEmpty)
    }

    @Test func gridDoesNotCountTheSameDepthPixelRepeatedly() throws {
        let geometry = try #require(FeatureDepthGeometry(frame()))
        let samples = geometry.samples(portraitBox: SIMD4(0.4, 0.4, 0.2, 0.2))
        #expect(samples.count <= 9)
        #expect(!samples.isEmpty)
    }

    private func flight(descending: Bool = false) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for step in 0..<5 {
            for x in [Float(-0.5), 0, 0.5] {
                for offset in [Float(0), 0.1, 0.2] {
                    result.append(SIMD3(x, Float(step) * (descending ? -0.17 : 0.17), -2 - Float(step) * 0.28 - offset))
                }
            }
        }
        return result
    }

    @Test func measuresVisibleTreadsInsteadOfDefaultSizedBox() throws {
        let result = StairsCheck.assess(flight(), viewer: SIMD3(0, 1.4, 0))
        #expect(result.verdict == .stairs)
        let measured = try #require(result.measurement)
        #expect(measured.treadCount == 5)
        #expect(abs(measured.medianRiser - 0.17) < 0.001)
        #expect(abs(measured.medianTread - 0.28) < 0.001)
        #expect(abs(measured.width - 1) < 0.001)
        #expect(abs(measured.run - 1.32) < 0.001)
        let footprint = try #require(measured.footprint())
        #expect(footprint.bottom == 0)
        #expect(abs((footprint.height ?? 0) - 0.68) < 0.001)
    }

    @Test func detectsDescendingFlightAndKeepsItsElevation() throws {
        let result = StairsCheck.assess(flight(descending: true), viewer: SIMD3(0, 1.4, 0))
        #expect(result.verdict == .stairs)
        let measured = try #require(result.measurement)
        #expect(measured.minimum.y < -0.6)
        #expect(measured.facing.y > 0) // uphill is back toward the camera
    }

    @Test func slopeAloneDoesNotProveStairs() {
        for slope in [Float(5), 20, 30, 40] {
            let points = (0..<150).map { i -> SIMD3<Float> in
                let run = Float(i) * 0.015
                return SIMD3(0, run * tan(slope * .pi / 180), -2 - run)
            }
            #expect(StairsCheck.classify(points, viewer: SIMD3(0, 1.4, 0)) != .stairs)
        }
        #expect(StairsCheck.classify([SIMD3(.nan, 0, 0)], viewer: .zero) == .inconclusive)
    }

    @Test func inconsistentStepsAndSingleStepRequireReview() {
        var points = flight()
        for i in points.indices where points[i].y > 0.3 { points[i].y += 0.12 }
        #expect(StairsCheck.classify(points, viewer: SIMD3(0, 1.4, 0)) != .stairs)
        #expect(StairsCheck.classify(Array(flight().prefix(18)), viewer: SIMD3(0, 1.4, 0)) != .stairs)
    }
}
