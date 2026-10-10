import Foundation
import simd
import Testing
@testable import AccessCore

private func pose(_ x: Float, _ z: Float = 0, yawDegrees: Float = 0) -> CaptureCoverage.Pose {
    let yaw = yawDegrees * .pi / 180
    return CaptureCoverage.Pose(position: [x, 1.4, z], forward: [-sin(yaw), 0, -cos(yaw)])
}

@Test func columnMajorPoseLooksAlongNegativeZ() throws {
    let p = try #require(CaptureCoverage.Pose(columnMajor: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 2, 1.5, -3, 1]))
    #expect(p.position == SIMD3(2, 1.5, -3))
    #expect(p.forward == SIMD3(0, 0, -1))
    #expect(CaptureCoverage.Pose(columnMajor: [1, 2, 3]) == nil)
    #expect(CaptureCoverage.Pose(columnMajor: [Float](repeating: .nan, count: 16)) == nil)
}

@Test func distanceCombinesTravelAndViewChange() {
    let a = pose(0)
    let turned = pose(0, yawDegrees: 90)
    #expect(abs(CaptureCoverage.viewAngle(a, turned) - .pi / 2) < 1e-5)
    #expect(abs(CaptureCoverage.distance(a, turned, metersPerRadian: 2) - .pi) < 1e-5)
    #expect(abs(CaptureCoverage.distance(a, pose(3), metersPerRadian: 2) - 3) < 1e-5)
}

@Test func redundancyKeepsEarlyRoomsAndDropsTheCluster() throws {
    // A long walk: the first room (x = 0) was seen once; the last room (x ≈ 20) many times.
    let poses = [pose(0), pose(5), pose(10), pose(20), pose(20.1), pose(20.3), pose(25)]
    let index = try #require(CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: 1))
    #expect([3, 4].contains(index), "evicted \(index)")
    // FIFO would have removed index 0, the only view of the first room.
    #expect(index != 0)
}

@Test func redundancyBreaksTiesTowardTheDenserNeighbourhood() throws {
    // 1 and 2 are mutual nearest neighbours; 2 also has 3 close by, so 2 is the more redundant.
    let poses = [pose(0), pose(4), pose(4.5), pose(5.2)]
    #expect(try #require(CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: 1)) == 2)
}

@Test func protectedPosesAreEvictedOnlyWhenNecessary() throws {
    let poses = [pose(0), pose(0.1), pose(10)]
    let index = try #require(CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: 1, protected: [0, 1]))
    #expect(index == 2)
    let all = try #require(CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: 1, protected: [0, 1, 2]))
    #expect([0, 1].contains(all))
    #expect(CaptureCoverage.mostRedundantIndex([], metersPerRadian: 1) == nil)
    #expect(CaptureCoverage.mostRedundantIndex([pose(0)], metersPerRadian: 1) == 0)
}

@Test func retentionBonusPrefersRemovingPlainFrames() throws {
    // 0/1 are twins and 2/3 are twins; frame 0 and 1 carry colour, so a depth-only twin goes first.
    let poses = [pose(0), pose(0.2), pose(10), pose(10.25)]
    let index = try #require(CaptureCoverage.mostRedundantIndex(
        poses, metersPerRadian: 1, retentionBonus: { $0 < 2 ? 0.3 : 0 }
    ))
    #expect([2, 3].contains(index))
}

@Test func viewDirectionAloneMakesAFrameValuable() throws {
    // Same spot, but frame 2 looks the other way: a turn adds coverage like travel does.
    let poses = [pose(0), pose(0.05), pose(0, yawDegrees: 180)]
    let index = try #require(CaptureCoverage.mostRedundantIndex(poses, metersPerRadian: 1))
    #expect(index != 2)
}

@Test func rotationAngleMeasuresRelativeOrientation() {
    let identity = matrix_identity_float4x4
    let yaw = simd_float4x4(simd_quatf(angle: 0.4, axis: [0, 1, 0]))
    var roll = simd_float4x4(simd_quatf(angle: 0.25, axis: [0, 0, 1]))
    roll.columns.3 = [3, 1, -2, 1]
    #expect(abs(CaptureCoverage.rotationAngle(identity, yaw) - 0.4) < 1e-4)
    #expect(abs(CaptureCoverage.rotationAngle(identity, roll) - 0.25) < 1e-4)
    #expect(CaptureCoverage.rotationAngle(yaw, yaw) < 1e-3)
}
