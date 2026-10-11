import Foundation
import simd

/// A server route checked against the measured floor on the device.
///
/// The server knows floors, connectors, features and the accessibility screening; its paths follow
/// a coarse skeleton graph and start at the nearest graph node. The device's occupancy grid is
/// exact for the floor it measured and knows live obstacles. Reconciling keeps the server's
/// structure and verdicts, draws this floor's legs with device geometry, and reports where the
/// two disagree. It never upgrades the server's accessibility status.
public struct ReconciledRoute: Sendable {
    public enum LegCheck: Equatable, Sendable {
        /// Device and server distances agree within tolerance.
        case confirmed
        /// The device found a shorter path to the same leg end.
        case shorterOnDevice(meters: Float)
        /// The device needs a longer path, e.g. around furniture the graph passes through.
        case longerOnDevice(meters: Float)
        /// No path at walking clearance on the device: a live obstacle or an outage blocks it.
        case blockedOnDevice
        /// Not on the floor this device has measured (or a floor connector).
        case notChecked
    }

    public struct Leg: Sendable {
        public var levelID: String?
        public var serverWaypoints: [SIMD2<Float>]
        /// Server distance from where this leg really begins (includes the walk to the first node).
        public var serverDistance: Float
        public var deviceRoute: Route?
        public var check: LegCheck
        /// Share of the server path lying on floor the device measured as free.
        public var onMeasuredFloor: Float?

        /// What to draw: the device path when it has one, else the server's.
        public var waypoints: [SIMD2<Float>] { deviceRoute?.waypoints ?? serverWaypoints }
        public var distance: Float { deviceRoute?.length ?? serverDistance }
    }

    public var route: ServerRoute
    public var legs: [Leg]
    /// Walking distance with device geometry where it was checked.
    public var distance: Float { legs.reduce(0) { $0 + $1.distance } }
    /// Every checked leg agrees with, or improves on, the server path.
    public var isConfirmed: Bool {
        legs.allSatisfy { leg in
            switch leg.check {
            case .confirmed, .shorterOnDevice, .notChecked: true
            case .longerOnDevice, .blockedOnDevice: false
            }
        }
    }
    /// The server found the route too narrow, yet the device routed this floor with at least the
    /// accessible-route clearance (0.45 m each side, about 0.9 m clear). Worth a closer look.
    public var deviceFoundWiderPath: Bool
}

public enum RouteReconciler {
    /// Distances within this fraction (plus `absoluteTolerance`) count as agreeing.
    public static let relativeTolerance: Float = 0.05
    public static let absoluteTolerance: Float = 1
    /// Server paths are sampled this often when measuring how much of them lies on free floor.
    static let sampleSpacing: Float = 0.25

    /// - Parameters:
    ///   - floorLevelID: The server level of the floor `planner` measured.
    ///   - start: Where the person stands; the first leg on this floor starts here instead of at the
    ///     server's snapped graph node.
    public static func reconcile(_ route: ServerRoute, planner: RoutePlanner, floorLevelID: String,
                                 start: SIMD2<Float>? = nil,
                                 conditions: RouteConditions = RouteConditions()) -> ReconciledRoute {
        var conditions = conditions
        conditions.minimumClearance = max(0.3, conditions.minimumClearance ?? 0.3)
        var legs: [ReconciledRoute.Leg] = []
        var startPending = start
        for leg in route.legs {
            let points = leg.polyline.map { SIMD2($0.x, $0.z) }
            guard leg.type == "walk", leg.levelID == floorLevelID, let last = points.last, let first = points.first else {
                legs.append(.init(levelID: leg.levelID, serverWaypoints: points, serverDistance: leg.distance,
                                  deviceRoute: nil, check: .notChecked, onMeasuredFloor: nil))
                continue
            }
            let begin = startPending ?? first
            let approach = startPending.map { simd_distance($0, first) } ?? 0
            startPending = nil
            let serverDistance = leg.distance + approach
            let goal = AccessPoint(kind: .destination, name: "Leg end",
                                   position: SIMD3(last.x, planner.map.floorY, last.y), source: .detected, confidence: 1)
            let device = planner.route(from: begin, to: goal, conditions: conditions)
            let check: ReconciledRoute.LegCheck
            if let device {
                let tolerance = relativeTolerance * serverDistance + absoluteTolerance
                let difference = device.length - serverDistance
                check = abs(difference) <= tolerance ? .confirmed
                    : difference < 0 ? .shorterOnDevice(meters: -difference) : .longerOnDevice(meters: difference)
            } else {
                check = .blockedOnDevice
            }
            legs.append(.init(levelID: leg.levelID, serverWaypoints: [begin] + points, serverDistance: serverDistance,
                              deviceRoute: device, check: check,
                              onMeasuredFloor: freeShare(points, grid: planner.grids[planner.grids.count - 1])))
        }
        let tooNarrow = route.accessibility.blocking.contains { $0.reason.contains("clear width") }
        let roomy = legs.contains { $0.deviceRoute.map { $0.clearance >= RoutePlanner.clearances[0] } ?? false }
            && !legs.contains { $0.check == .blockedOnDevice }
        return ReconciledRoute(route: route, legs: legs, deviceFoundWiderPath: tooNarrow && roomy)
    }

    /// Fraction of evenly spaced samples along `points` that fall on free cells of `grid`.
    static func freeShare(_ points: [SIMD2<Float>], grid: OccupancyGrid) -> Float? {
        guard points.count >= 2 else { return nil }
        var free = 0, total = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(1, Int((simd_distance(a, b) / sampleSpacing).rounded(.up)))
            for step in 0..<steps {
                let point = a + (b - a) * (Float(step) / Float(steps))
                total += 1
                if let index = grid.index(containing: point), !grid.isBlocked(index) { free += 1 }
            }
        }
        return total == 0 ? nil : Float(free) / Float(total)
    }
}
