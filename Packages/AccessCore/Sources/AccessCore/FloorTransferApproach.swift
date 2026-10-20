import Foundation
import simd

/// A route ends at a connector on the current floor. Its service to another floor
/// must be checked on the building signs; independent scan frames are never joined.
public struct FloorTransferApproach: Sendable {
    public let kind: BuildingConnectorKind
    public let destination: AccessPoint

    public init(kind: BuildingConnectorKind, destination: AccessPoint) {
        self.kind = kind
        self.destination = destination
    }

    public static func candidates(in map: VenueMap, preference: RoutePreference) -> [Self] {
        var result = map.points.filter { $0.kind == .elevator }.map {
            Self(kind: .elevator, destination: $0)
        }
        guard preference == .fastest else { return result }
        for stairs in map.footprints where stairs.kind == .stairs {
            guard stairs.size.x.isFinite, stairs.size.y.isFinite,
                  stairs.size.x > 0, stairs.size.y > 0, stairs.yaw.isFinite,
                  stairs.center.x.isFinite, stairs.center.y.isFinite else { continue }
            // Stop outside each end of the flight. Stairs remain blocked in the
            // walking grid, even when the person is allowed to use them next.
            let alongX = stairs.size.x >= stairs.size.y
            for sign: Float in [-1, 1] {
                let local = alongX ? SIMD2(sign * (stairs.size.x / 2 + 0.6), 0)
                    : SIMD2(0, sign * (stairs.size.y / 2 + 0.6))
                let landing = stairs.floorPoint(local: local)
                result.append(Self(kind: .stairs, destination: AccessPoint(kind: .destination,
                    name: "Stairs", position: SIMD3(landing.x, map.floorY, landing.y),
                    source: .manual, confidence: 1)))
            }
        }
        return result
    }

    public static func nearestRoute(from start: SIMD2<Float>, planner: RoutePlanner,
                                    candidates: [Self], conditions: RouteConditions) -> Route? {
        candidates.filter { conditions.preference != .stepFree || !$0.kind.involvesSteps }
            .compactMap { planner.route(from: start, to: $0.destination, conditions: conditions) }
            .min { $0.estimatedSeconds < $1.estimatedSeconds }
    }
}
