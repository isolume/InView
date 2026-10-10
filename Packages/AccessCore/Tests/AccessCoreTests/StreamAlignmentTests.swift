import Foundation
import simd
import Testing
@testable import AccessCore

private func alignmentArray(_ matrix: simd_float4x4) -> [Float] {
    [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
}

private func alignmentPose(_ timestamp: Double, original: simd_float4x4 = matrix_identity_float4x4,
                           correction: simd_float4x4 = matrix_identity_float4x4) -> StreamPoseCorrection {
    StreamPoseCorrection(frameID: "frame-\(timestamp)", timestampSeconds: timestamp,
                         originalMapFromCamera: alignmentArray(original),
                         optimizedMapFromCamera: alignmentArray(correction * original))
}

private func alignmentTransform(x: Float = 0, y: Float = 0, z: Float = 0, yaw: Float = 0) -> simd_float4x4 {
    var transform = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
    transform.columns.3 = SIMD4(x, y, z, 1)
    return transform
}

private func alignmentNear(_ a: simd_float4x4, _ b: simd_float4x4, tolerance: Float = 0.0001) -> Bool {
    zip(alignmentArray(a), alignmentArray(b)).allSatisfy { abs($0 - $1) <= tolerance }
}

private func alignmentResult() throws -> StreamResult {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { root = root.deletingLastPathComponent() }
    var capture = try JSONDecoder().decode(CaptureBundle.self, from: Data(contentsOf: root.appendingPathComponent("backend/examples/scan.json")))
    var scene = try JSONDecoder().decode(ProcessedScene.self, from: rustSceneFixture)
    capture.id = UUID().uuidString
    scene.sourceScanID = capture.id
    return StreamResult(capture: capture, scene: scene)
}

struct StreamAlignmentTests {
    @Test func unchangedPosesAndEmptyNoLoopAlignmentPreserveOriginalCoordinates() throws {
        let alignment = StreamAlignment(optimized: false, frames: [
            alignmentPose(1, original: alignmentTransform(x: 5, y: 2, z: -3, yaw: 0.7)),
            alignmentPose(2, original: alignmentTransform(x: 8, y: 2, z: 4, yaw: -0.9)),
        ])
        try alignment.validate()
        #expect(!alignment.materiallyChanged)
        for timestamp in [0.0, 1, 1.5, 2, 3] {
            #expect(alignmentNear(alignment.correction(at: timestamp), matrix_identity_float4x4))
        }
        let empty = StreamAlignment(optimized: false, frames: [])
        try empty.validate()
        #expect(alignmentNear(empty.correction(at: 1), matrix_identity_float4x4))
        #expect(!empty.materiallyChanged)
    }

    @Test func translationsInterpolateByTimeAndClampAtEndpoints() throws {
        let alignment = StreamAlignment(optimized: true, frames: [
            alignmentPose(10),
            alignmentPose(14, original: alignmentTransform(x: 7, z: 2), correction: alignmentTransform(x: 2, y: 0.5, z: -1)),
        ], initialCost: 5, finalCost: 2)
        try alignment.validate()
        #expect(alignment.materiallyChanged)
        #expect(alignmentNear(alignment.correction(at: 8), matrix_identity_float4x4))
        #expect(alignmentNear(alignment.correction(at: 12), alignmentTransform(x: 1, y: 0.25, z: -0.5)))
        #expect(alignmentNear(alignment.correction(at: 20), alignmentTransform(x: 2, y: 0.5, z: -1)))
    }

    @Test func correctionOrderAndQuaternionInterpolationPreserveRigidPoses() throws {
        let original = alignmentTransform(x: 3, y: 1, z: -2, yaw: -0.6)
        let correction = alignmentTransform(x: 2, z: 1, yaw: .pi * 0.75)
        let pose = alignmentPose(2, original: original, correction: correction)
        #expect(alignmentNear(pose.transform, correction))
        let alignment = StreamAlignment(optimized: true, frames: [alignmentPose(0), pose])
        try alignment.validate()
        #expect(alignmentNear(alignment.correction(at: 1), alignmentTransform(x: 1, z: 0.5, yaw: .pi * 0.375)))
        let transform = alignment.correction(at: 1)
        #expect(validRigidTransform(alignmentArray(transform)))
        let correctedPoint = pose.transform * (original * SIMD4<Float>(0, 0, -1, 1))
        let expectedPoint = (correction * original) * SIMD4<Float>(0, 0, -1, 1)
        #expect(simd_length(correctedPoint - expectedPoint) < 0.0001)
    }

    @Test func quaternionInterpolationTakesTheShortPathAcrossTheAngleBoundary() throws {
        let degrees = Float.pi / 180
        let alignment = StreamAlignment(optimized: true, frames: [
            alignmentPose(0),
            alignmentPose(1, correction: alignmentTransform(yaw: 170 * degrees)),
            alignmentPose(2, correction: alignmentTransform(yaw: -170 * degrees)),
        ])
        try alignment.validate()
        #expect(alignmentNear(alignment.correction(at: 1.5), alignmentTransform(yaw: .pi)))
    }

    @Test func materialChangeToleranceDistinguishesNumericalAndRealCorrections() throws {
        for (correction, expected) in [
            (alignmentTransform(x: 0.004, yaw: 0.004), false),
            (alignmentTransform(x: 0.006), true),
            (alignmentTransform(yaw: 0.006), true),
        ] {
            let alignment = StreamAlignment(optimized: true, frames: [alignmentPose(0), alignmentPose(1, correction: correction)])
            try alignment.validate()
            #expect(alignment.materiallyChanged == expected)
        }
    }

    @Test func invalidRigidPosesGaugeIdentifiersTimesAndCostsAreRejected() throws {
        let valid = StreamAlignment(optimized: true, frames: [alignmentPose(0), alignmentPose(1, correction: alignmentTransform(x: 1))])
        var malformed: [StreamAlignment] = []
        var scaled = valid
        scaled.frames[1].optimizedMapFromCamera[0] = 2
        malformed.append(scaled)
        var reflected = valid
        reflected.frames[1].optimizedMapFromCamera[0] = -1
        malformed.append(reflected)
        var short = valid
        short.frames[1].originalMapFromCamera = [1, 2, 3]
        malformed.append(short)
        var gauge = valid
        gauge.frames[0] = alignmentPose(0, correction: alignmentTransform(x: 0.01))
        malformed.append(gauge)
        var unsorted = valid
        unsorted.frames.reverse()
        malformed.append(unsorted)
        var repeatedTime = valid
        repeatedTime.frames[1].timestampSeconds = 0
        malformed.append(repeatedTime)
        var repeatedID = valid
        repeatedID.frames[1].frameID = repeatedID.frames[0].frameID
        malformed.append(repeatedID)
        var negativeTime = valid
        negativeTime.frames[0].timestampSeconds = -1
        malformed.append(negativeTime)
        var invalidCost = valid
        invalidCost.finalCost = .nan
        malformed.append(invalidCost)
        var tooMany = valid
        tooMany.frames = (0..<65).map { alignmentPose(Double($0)) }
        malformed.append(tooMany)
        var unacceptedChanges = valid
        unacceptedChanges.optimized = false
        malformed.append(unacceptedChanges)
        var wrongFrame = valid
        wrongFrame.referenceFrame = "different-session"
        malformed.append(wrongFrame)
        for alignment in malformed {
            #expect(throws: StreamAlignment.invalidResponse) { try alignment.validate() }
        }
    }

    @Test func resultRoundTripValidatesAlignmentAndMatchingMetadata() throws {
        var result = try alignmentResult()
        let oldResult = try JSONDecoder().decode(StreamResult.self, from: JSONEncoder().encode(result))
        #expect(oldResult.alignment == nil)
        try oldResult.validate(streamID: result.capture.id)
        result.alignment = StreamAlignment(optimized: true, frames: [alignmentPose(0), alignmentPose(1, correction: alignmentTransform(x: 1))],
                                           constraints: [.object(["kind": .string("loop_closure"), "inliers": .number(18)])],
                                           initialCost: 0.1, finalCost: 0.01)
        result.capture.metadata = .object(["alignment_optimized": .bool(true), "alignment_refined": .bool(true)])
        let restored = try JSONDecoder().decode(StreamResult.self, from: JSONEncoder().encode(result))
        #expect(restored == result)
        try restored.validate(streamID: result.capture.id)
        #expect(restored.alignment?.materiallyChanged == true)
        result.capture.metadata = .object(["alignment_optimized": .bool(false)])
        #expect(throws: StreamAlignment.invalidResponse) { try result.validate(streamID: result.capture.id) }
        result.capture.metadata = .object(["alignment_refined": .bool(true)])
        result.alignment = nil
        #expect(throws: StreamAlignment.invalidResponse) { try result.validate(streamID: result.capture.id) }
    }
}
