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

/// Finds wheelchair routes over a saved map. Immutable, so it is safe to use off the main thread.
public final class RoutePlanner: Sendable {
    /// Clearances to try, widest first. 0.45 m keeps 90 cm passages (ADA 36 in); the tighter
    /// levels keep navigation working in cramped spaces like a hackathon floor.
    public static let clearances: [Float] = [0.45, 0.3, 0.15]
    /// How far the user may stand from free floor (e.g. pressed against a table) and still get a route.
    static let startSearchRadius: Float = 1.5
    /// How far a route may end from the access point itself, which often sits on a wall.
    static let goalSearchRadius: Float = 1.5

    public let map: VenueMap
    public let grids: [OccupancyGrid]

    public init(map: VenueMap) {
        self.map = map
        grids = Self.clearances.map { OccupancyGrid(map: map, clearance: $0) }
    }

    /// The route to whichever access point is shortest to roll to, which is not always the closest in a straight line.
    public func nearestRoute(from start: SIMD2<Float>) -> Route? {
        bestRoute(from: start, among: map.points)
    }

    /// Recomputes a route to the same destination from the user's new position.
    public func reroute(_ route: Route, from start: SIMD2<Float>) -> Route? {
        let grid = grids[route.level]
        if let startIndex = grid.nearestFreeIndex(to: start, within: Self.startSearchRadius) {
            let result = grid.search(from: startIndex, to: route.goalIndex)
            if result.cost[route.goalIndex].isFinite {
                return makeRoute(on: grid, level: route.level, parents: result.parent, goal: route.goalIndex, destination: route.destination)
            }
        }
        return bestRoute(from: start, among: [route.destination])
    }

    private func bestRoute(from start: SIMD2<Float>, among points: [AccessPoint]) -> Route? {
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
        let length = zip(waypoints, waypoints.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
        return Route(destination: destination, waypoints: waypoints, length: length, clearance: grid.clearance, level: level, goalIndex: goal)
    }
}
