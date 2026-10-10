import Foundation
import simd
import Testing
@testable import AccessCore

private let routeAhead: [SIMD2<Float>] = [[0, 0], [0, -5]]

/// A dense block of points, like LiDAR returns off a chair or box.
private func box(at center: SIMD2<Float>, size: Float = 0.4, height: Float = 0.8) -> [SIMD3<Float>] {
    var points: [SIMD3<Float>] = []
    for x in stride(from: -size / 2, through: size / 2, by: 0.05) {
        for z in stride(from: -size / 2, through: size / 2, by: 0.05) {
            for y in stride(from: 0.15, through: height, by: 0.1) {
                points.append([center.x + x, y, center.y + z])
            }
        }
    }
    return points
}

@Test func findsAChairInThePath() {
    let obstacles = ObstacleFinder.obstacles(in: box(at: [0, -2]), along: routeAhead, floorY: 0)
    #expect(obstacles.count == 1)
    #expect(simd_distance(obstacles[0], [0, -2]) < 0.2)
}

@Test func ignoresThingsBesideTheRoute() {
    #expect(ObstacleFinder.obstacles(in: box(at: [1.5, -2]), along: routeAhead, floorY: 0).isEmpty)
}

@Test func ignoresThingsRightAtTheUsersFeet() {
    #expect(ObstacleFinder.obstacles(in: box(at: [0, -0.3], size: 0.2), along: routeAhead, floorY: 0).isEmpty)
}

@Test func doesNotMistakeARampForAnObstacle() {
    // A 4.5° ramp rising along the route: lots of points, but each spot is a thin surface.
    var ramp: [SIMD3<Float>] = []
    for z in stride(from: Float(-1), through: -4, by: -0.02) {
        for x in stride(from: Float(-0.4), through: 0.4, by: 0.05) {
            ramp.append([x, 0.12 + (-1 - z) * tan(4.5 * .pi / 180), z])
        }
    }
    #expect(ObstacleFinder.obstacles(in: ramp, along: routeAhead, floorY: 0).isEmpty)
}

private func tiltedSamples(degrees: Float) -> [SIMD3<Float>] {
    var samples: [SIMD3<Float>] = []
    var noise = SystemRandomNumberGenerator()
    for x in stride(from: Float(-0.5), through: 0.5, by: 0.1) {
        for z in stride(from: Float(-0.5), through: 0.5, by: 0.1) {
            let y = tan(degrees * .pi / 180) * z + Float.random(in: -0.005...0.005, using: &noise)
            samples.append([x + 2, y + 0.3, z - 1])
        }
    }
    return samples
}

@Test func measuresARampSlope() throws {
    let slope = try #require(SurfaceFit.slopeDegrees(of: tiltedSamples(degrees: 4)))
    #expect(abs(slope - 4) < 0.3)
}

@Test func measuresSlopeDespiteARailingInTheSamples() throws {
    var samples = tiltedSamples(degrees: 6)
    for i in 0..<20 { samples.append([2.5, 0.9 + Float(i) * 0.02, -1]) }
    let slope = try #require(SurfaceFit.slopeDegrees(of: samples))
    #expect(abs(slope - 6) < 0.5)
}

@Test func refusesToGuessFromTooFewSamples() {
    #expect(SurfaceFit.slopeDegrees(of: Array(tiltedSamples(degrees: 4).prefix(4))) == nil)
}
