import Foundation
import simd

public struct Route: Sendable {
    public let destination: AccessPoint
    /// Smoothed path on the floor as (x, z), starting where the user stands.
    public let waypoints: [SIMD2<Float>]
    /// Meters along the waypoints.
    public let length: Float
    /// Distance the route keeps from obstacles. Below the ideal when the space is cramped.
    public let clearance: Float
    public let preference: RoutePreference

    /// A distance-based estimate using the same speed for both preferences.
    /// Building transitions and waiting times are handled by the building route.
    public var estimatedSeconds: TimeInterval { Double(length) / preference.walkingSpeedMetersPerSecond }

    let level: Int
    let goalIndex: Int
    let requiredClearance: Float?
    let requiresMeasuredRampSlope: Bool

    public var isNarrow: Bool { clearance < RoutePlanner.clearances[0] }

    init(destination: AccessPoint, waypoints: [SIMD2<Float>], length: Float, clearance: Float,
         level: Int, goalIndex: Int, preference: RoutePreference = .stepFree,
         requiredClearance: Float? = nil, requiresMeasuredRampSlope: Bool = false) {
        self.destination = destination
        self.waypoints = waypoints
        self.length = length
        self.clearance = clearance
        self.level = level
        self.goalIndex = goalIndex
        self.preference = preference
        self.requiredClearance = requiredClearance
        self.requiresMeasuredRampSlope = requiresMeasuredRampSlope
    }
}

/// What changes while the user is moving: outages the crew reports and obstacles the camera sees.
public struct RouteConditions: Sendable {
    /// Access points reported out of service.
    public var unavailable: Set<UUID>
    /// Floor positions of things blocking the way that aren't on the saved map.
    public var obstacles: [SIMD2<Float>]
    /// Minimum distance from obstacles. When set, routing never tries a tighter clearance.
    /// Leave unset for audits that need to identify cramped passages.
    public var minimumClearance: Float?
    /// Reject ramps without a measured, finite incline. Width and incline are separate requirements.
    public var requiresMeasuredRampSlope: Bool
    public var preference: RoutePreference

    public init(unavailable: Set<UUID> = [], obstacles: [SIMD2<Float>] = [], minimumClearance: Float? = nil,
                requiresMeasuredRampSlope: Bool = false, preference: RoutePreference = .stepFree) {
        self.unavailable = unavailable
        self.obstacles = obstacles
        self.minimumClearance = minimumClearance
        self.requiresMeasuredRampSlope = requiresMeasuredRampSlope
        self.preference = preference
    }
}

/// Finds routes over measured floor. Immutable, so it is safe to use off the main thread.
public final class RoutePlanner: Sendable {
    /// Clearances to try, widest first. 0.45 m keeps 90 cm passages; tighter levels can
    /// identify cramped passages during audits. Navigation can require a minimum clearance.
    public static let clearances: [Float] = [0.45, 0.3, 0.15]
    /// How far the user may stand from free floor (e.g. pressed against a table) and still get a route.
    static let startSearchRadius: Float = 1.5
    /// How far a route may end from the access point itself, which often sits on a wall.
    static let goalSearchRadius: Float = 1.5
    /// Rough footprint of an obstacle the camera sees (a chair, a cart).
    static let obstacleRadius: Float = 0.3

    public let map: VenueMap
    public let grids: [OccupancyGrid]

    public init(map: VenueMap) {
        self.map = map
        grids = Self.clearances.map { OccupancyGrid(map: map, clearance: $0) }
    }

    /// The route to a usable access point. Step-free prefers wider passages;
    /// Fastest compares distance across every permitted clearance.
    public func nearestRoute(from start: SIMD2<Float>, conditions: RouteConditions = RouteConditions()) -> Route? {
        let available = map.points.filter {
            ($0.kind == .elevator || $0.kind == .ramp) && isEligible($0, conditions: conditions)
        }
        let grids = grids(avoiding: conditions.obstacles)
        return bestRoute(from: start, among: available, grids: grids, conditions: conditions)
    }

    /// Routes to a selected point, including a named room, while respecting live conditions.
    public func route(from start: SIMD2<Float>, to destination: AccessPoint, conditions: RouteConditions = RouteConditions()) -> Route? {
        guard isEligible(destination, conditions: conditions) else { return nil }
        return bestRoute(from: start, among: [destination], grids: grids(avoiding: conditions.obstacles),
                         conditions: conditions)
    }

    /// The widest usable clearance to each point, in the supplied order. Unlike creating
    /// individual routes, an audit shares one entrance search per clearance and needs no paths.
    func reachableClearances(from start: SIMD2<Float>, to points: [AccessPoint],
                             isCancelled: () -> Bool = { false }) throws -> [Float?] {
        guard !isCancelled() else { throw CancellationError() }
        var clearances = [Float?](repeating: nil, count: points.count)
        guard !points.isEmpty else { return clearances }
        for grid in grids {
            guard !isCancelled() else { throw CancellationError() }
            guard let startIndex = grid.nearestFreeIndex(to: start, within: Self.startSearchRadius) else { continue }
            let search = try grid.search(from: startIndex, storingParents: false, isCancelled: isCancelled)
            for (index, point) in points.enumerated() where clearances[index] == nil {
                guard !isCancelled() else { throw CancellationError() }
                // Match route(to:)'s goal snapping exactly, including points measured on a wall.
                if grid.closestIndex(to: point.floorPoint, within: Self.goalSearchRadius,
                                     where: { search.cost[$0].isFinite }) != nil {
                    clearances[index] = grid.clearance
                }
            }
            if clearances.allSatisfy({ $0 != nil }) { break }
        }
        return clearances
    }

    /// Recomputes a route from the user's new position, preserving its destination,
    /// preference and requirements. Choose a new route to change preference.
    public func reroute(_ route: Route, from start: SIMD2<Float>, conditions: RouteConditions = RouteConditions()) -> Route? {
        var conditions = conditions
        conditions.preference = route.preference
        conditions.requiresMeasuredRampSlope = conditions.requiresMeasuredRampSlope || route.requiresMeasuredRampSlope
        guard isEligible(route.destination, conditions: conditions),
              conditions.minimumClearance?.isFinite != false else { return nil }
        let grids = grids(avoiding: conditions.obstacles)
        if route.preference == .fastest {
            // A previous path happening to be wide must not prevent Fastest from
            // considering a shorter walking passage when conditions change.
            conditions.minimumClearance = max(0.3, route.requiredClearance ?? 0.3,
                                              conditions.minimumClearance ?? 0.3)
            return bestRoute(from: start, among: [route.destination], grids: grids, conditions: conditions)
        }
        let minimumClearance = max(route.clearance, conditions.minimumClearance ?? route.clearance)
        conditions.minimumClearance = minimumClearance
        let grid = grids[route.level]
        if grid.clearance >= minimumClearance,
           let startIndex = grid.nearestFreeIndex(to: start, within: Self.startSearchRadius), !grid.isBlocked(route.goalIndex) {
            let result = grid.search(from: startIndex, to: route.goalIndex)
            if result.cost[route.goalIndex].isFinite {
                return makeRoute(on: grid, level: route.level, parents: result.parent, goal: route.goalIndex,
                                 destination: route.destination, conditions: conditions)
            }
        }
        return bestRoute(from: start, among: [route.destination], grids: grids, conditions: conditions)
    }

    private func grids(avoiding obstacles: [SIMD2<Float>]) -> [OccupancyGrid] {
        obstacles.isEmpty ? grids : grids.map { $0.blocking(obstacles, radius: Self.obstacleRadius) }
    }

    private func isEligible(_ point: AccessPoint, conditions: RouteConditions) -> Bool {
        guard !conditions.unavailable.contains(point.id) else { return false }
        if conditions.preference == .stepFree, point.isTooSteep { return false }
        if point.kind == .ramp, conditions.requiresMeasuredRampSlope || conditions.preference == .fastest {
            guard let slope = point.slopeDegrees, slope.isFinite, slope >= 0, slope < 90 else { return false }
        }
        return true
    }

    private func bestRoute(from start: SIMD2<Float>, among points: [AccessPoint], grids: [OccupancyGrid],
                           conditions: RouteConditions) -> Route? {
        guard !points.isEmpty, conditions.minimumClearance?.isFinite != false else { return nil }
        var conditions = conditions
        if conditions.preference == .fastest {
            // Fastest is a walking route, never the very tight audit-only grid.
            conditions.minimumClearance = max(0.3, conditions.minimumClearance ?? 0.3)
        }
        var fastest: Route?
        for (level, grid) in grids.enumerated() {
            if let minimumClearance = conditions.minimumClearance, !(grid.clearance >= minimumClearance) { continue }
            guard let startIndex = grid.nearestFreeIndex(to: start, within: Self.startSearchRadius) else { continue }
            let result = grid.search(from: startIndex)
            var best: (point: AccessPoint, goal: Int, cost: Float)?
            for point in points {
                guard let goal = grid.closestIndex(to: point.floorPoint, within: Self.goalSearchRadius, where: { result.cost[$0].isFinite }) else { continue }
                if conditions.preference == .fastest {
                    let candidate = makeRoute(on: grid, level: level, parents: result.parent, goal: goal,
                                              destination: point, conditions: conditions)
                    if fastest == nil || candidate.length < fastest!.length {
                        fastest = candidate
                    }
                    continue
                }
                if best == nil || result.cost[goal] < best!.cost {
                    best = (point, goal, result.cost[goal])
                }
            }
            if let best {
                return makeRoute(on: grid, level: level, parents: result.parent, goal: best.goal,
                                 destination: best.point, conditions: conditions)
            }
        }
        return fastest
    }

    private func makeRoute(on grid: OccupancyGrid, level: Int, parents: [Int32], goal: Int,
                           destination: AccessPoint, conditions: RouteConditions) -> Route {
        let waypoints = grid.smooth(grid.path(to: goal, parents: parents).map(grid.center(of:)))
        return Route(destination: destination, waypoints: waypoints, length: Polyline.length(of: waypoints),
                     clearance: grid.clearance, level: level, goalIndex: goal, preference: conditions.preference,
                     requiredClearance: conditions.minimumClearance, requiresMeasuredRampSlope: conditions.requiresMeasuredRampSlope)
    }
}
