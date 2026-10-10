import Foundation
import simd
@testable import AccessCore

// All maps are an 8 x 6 m room spanning (-4, -3) to (4, 3), optionally split by a wall at x = 0.

func wall(from a: SIMD2<Float>, to b: SIMD2<Float>) -> Footprint {
    let direction = b - a
    return Footprint(kind: .wall, center: (a + b) / 2, size: SIMD2(simd_length(direction), 0.15), yaw: atan2(direction.y, direction.x))
}

func dividerDoor(at z: Float, width: Float) -> Footprint {
    Footprint(kind: .door, center: SIMD2(0, z), size: SIMD2(width, 0.15), yaw: .pi / 2)
}

func point(_ kind: AccessPoint.Kind, _ x: Float, _ z: Float) -> AccessPoint {
    AccessPoint(kind: kind, position: SIMD3(x, 0, z), source: .manual, confidence: 1)
}

func room(_ extra: [Footprint] = [], points: [AccessPoint]) -> VenueMap {
    let outer = [
        wall(from: [-4, -3], to: [4, -3]),
        wall(from: [4, -3], to: [4, 3]),
        wall(from: [4, 3], to: [-4, 3]),
        wall(from: [-4, 3], to: [-4, -3]),
    ]
    return VenueMap(floorY: 0, footprints: outer + extra, points: points)
}

let divider = wall(from: [0, -3], to: [0, 3])

/// Where the route crosses x = 0, as a z coordinate.
func crossing(of route: Route, at x: Float = 0) -> Float? {
    for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) where (a.x < x) != (b.x < x) {
        let t = (x - a.x) / (b.x - a.x)
        return a.y + (b.y - a.y) * t
    }
    return nil
}
