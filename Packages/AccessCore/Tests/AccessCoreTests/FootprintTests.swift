import simd
import Testing
@testable import AccessCore

@Test func legacyFootprintProjectionDoesNotInventVerticalMeasurements() {
    let pose = simd_float4x4(columns: ([0, 0, -1, 0], [0, 1, 0, 0], [1, 0, 0, 0], [4, 3, -2, 1]))
    let footprint = Footprint(kind: .wall, transform: pose, width: 2, depth: 0.15)
    #expect(footprint.center == [4, -2])
    #expect(footprint.size == [2, 0.15])
    #expect(abs(footprint.yaw + .pi / 2) < 0.0001)
    #expect(footprint.height == nil)
    #expect(footprint.bottom == nil)
    #expect(footprint.furniture == nil)
}

@Test func measuredFootprintKeepsFurnitureAndHeightAlongsideLegacyProjection() {
    var pose = matrix_identity_float4x4
    pose.columns.3 = [4, 3, -2, 1]
    let footprint = Footprint(kind: .obstacle, transform: pose, dimensions: [2, 1, 0.8], furniture: .sofa)
    let legacy = Footprint(kind: .obstacle, transform: pose, width: 2, depth: 0.8)
    #expect(footprint.corners == legacy.corners)
    #expect(footprint.bottom == 2.5)
    #expect(footprint.height == 1)
    #expect(footprint.furniture == .sofa)
}
