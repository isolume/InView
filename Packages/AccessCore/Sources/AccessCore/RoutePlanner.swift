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

    let level: Int
    let goalIndex: Int

    public var isNarrow: Bool { clearance < RoutePlanner.clearances[0] }
}

/// What changes while the user is moving: outages the crew reports and obstacles the camera sees.
public struct RouteConditions: Sendable {
    /// Access points reported out of service.
    public var unavailable: Set<UUID>
    /// Floor positions of things blocking the way that aren't on the saved map.
    public var obstacles: [SIMD2<Float>]

    public init(unavailable: Set<UUID> = [], obstacles: [SIMD2<Float>] = []) {
        self.unavailable = unavailable
        self.obstacles = obstacles
    }
}

/// Finds wheelchair routes over a saved map. Immutable, so it is safe to use off the main thread.
public final class RoutePlanner: Sendable {
    /// Clearances to try, widest first. 0.45 m keeps 90 cm passages (ADA 36 in); the tighter
    /// levels keep navigation working in cramped spaces like a hackathon floor.
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

    /// The route to whichever usable access point is shortest to roll to, which is not always the
    /// closest in a straight line. Too-steep ramps are only considered when nothing else is reachable.
    public func nearestRoute(from start: SIMD2<Float>, conditions: RouteConditions = RouteConditions()) -> Route? {
        let available = map.points.filter { !conditions.unavailable.contains($0.id) }
        let grids = grids(avoiding: conditions.obstacles)
        return bestRoute(from: start, among: available.filter { !$0.isTooSteep }, grids: grids)
            ?? bestRoute(from: start, among: available.filter(\.isTooSteep), grids: grids)
    }

    /// Recomputes a route from the user's new position. Keeps the destination when it is still usable
    /// and reachable; otherwise picks the next best one.
    public func reroute(_ route: Route, from start: SIMD2<Float>, conditions: RouteConditions = RouteConditions()) -> Route? {
        guard !conditions.unavailable.contains(route.destination.id) else {
            return nearestRoute(from: start, conditions: conditions)
        }
        let grids = grids(avoiding: conditions.obstacles)
        let grid = grids[route.level]
        if let startIndex = grid.nearestFreeIndex(to: start, within: Self.startSearchRadius), !grid.isBlocked(route.goalIndex) {
            let result = grid.search(from: startIndex, to: route.goalIndex)
            if result.cost[route.goalIndex].isFinite {
                return makeRoute(on: grid, level: route.level, parents: result.parent, goal: route.goalIndex, destination: route.destination)
            }
        }
        return bestRoute(from: start, among: [route.destination], grids: grids)
            ?? nearestRoute(from: start, conditions: conditions)
    }

    private func grids(avoiding obstacles: [SIMD2<Float>]) -> [OccupancyGrid] {
        obstacles.isEmpty ? grids : grids.map { $0.blocking(obstacles, radius: Self.obstacleRadius) }
    }

    private func bestRoute(from start: SIMD2<Float>, among points: [AccessPoint], grids: [OccupancyGrid]) -> Route? {
        guard !points.isEmpty else { return nil }
        for (level, grid) in grids.enumerated() {
            guard let startIndex = grid.nearestFreeIndex(to: start, within: Self.startSearchRadius) else { continue }
            let result = grid.search(from: startIndex)
            var best: (point: AccessPoint, goal: Int, cost: Float)?
            for point in points {
                guard let goal = grid.closestIndex(to: point.floorPoint, within: Self.goalSearchRadius, where: { result.cost[$0].isFinite }) else { continue }
                if best == nil || result.cost[goal] < best!.cost {
                    best = (point, goal, result.cost[goal])
                }
            }
            if let best {
                return makeRoute(on: grid, level: level, parents: result.parent, goal: best.goal, destination: best.point)
            }
        }
        return nil
    }

    private func makeRoute(on grid: OccupancyGrid, level: Int, parents: [Int32], goal: Int, destination: AccessPoint) -> Route {
        let waypoints = grid.smooth(grid.path(to: goal, parents: parents).map(grid.center(of:)))
        return Route(destination: destination, waypoints: waypoints, length: Polyline.length(of: waypoints), clearance: grid.clearance, level: level, goalIndex: goal)
    }
}
