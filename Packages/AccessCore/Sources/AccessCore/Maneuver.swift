import Foundation
import simd

/// A turn along a route, for spoken directions.
public struct Maneuver: Equatable, Sendable {
    public enum Turn: Sendable {
        case slightLeft
        case left
        case slightRight
        case right

        public var phrase: String {
            switch self {
            case .slightLeft: "bear left"
            case .left: "turn left"
            case .slightRight: "bear right"
            case .right: "turn right"
            }
        }
    }

    public let turn: Turn
    /// The corner on the floor, as (x, z).
    public let position: SIMD2<Float>
    /// Meters along the route from its start (where the user is) to the corner.
    public let distance: Float
}

extension Route {
    /// Corners sharper than this get announced.
    static let announcedTurnAngle: Float = 30
    /// Corners sharper than this are a full turn rather than a bend.
    static let sharpTurnAngle: Float = 60

    /// The next corner worth announcing, if any.
    public var nextManeuver: Maneuver? { maneuvers(limit: 1).first }

    /// Every corner worth announcing, in order, for a list of directions.
    public var maneuvers: [Maneuver] { maneuvers(limit: .max) }

    private func maneuvers(limit: Int) -> [Maneuver] {
        var found: [Maneuver] = []
        guard waypoints.count > 2 else { return found }
        var travelled: Float = 0
        for i in 1..<(waypoints.count - 1) {
            let incoming = waypoints[i] - waypoints[i - 1]
            let outgoing = waypoints[i + 1] - waypoints[i]
            travelled += simd_length(incoming)
            guard simd_length(incoming) > 1e-3, simd_length(outgoing) > 1e-3 else { continue }
            let a = simd_normalize(incoming), b = simd_normalize(outgoing)
            let angle = acos(simd_clamp(simd_dot(a, b), -1, 1)) * 180 / .pi
            guard angle >= Self.announcedTurnAngle else { continue }
            // Floor coordinates are (x, z) with y up, so a positive cross product is a turn to the right.
            let isRight = a.x * b.y - a.y * b.x > 0
            let turn: Maneuver.Turn = angle < Self.sharpTurnAngle
                ? (isRight ? .slightRight : .slightLeft)
                : (isRight ? .right : .left)
            found.append(Maneuver(turn: turn, position: waypoints[i], distance: travelled))
            if found.count == limit { break }
        }
        return found
    }
}
