import Foundation
import simd

/// Routes within one displayed floor while preserving its independently measured elevations.
/// Surface searches use the ordinary planner's occupancy grids; only explicit connectors join zones.
public final class ElevatedFloorRoutePlanner: Sendable {
    public let map: ElevatedFloorMap
    private let planners: [String: RoutePlanner]

    public init(map: ElevatedFloorMap) throws {
        try map.validate()
        self.map = map
        planners = Dictionary(uniqueKeysWithValues: map.zones.map { ($0.id, RoutePlanner(map: $0.map)) })
    }

    /// Unscoped `conditions.obstacles` apply only to the starting zone. Obstacles at other
    /// elevations must be supplied under their zone ID. All surface legs require measured floor,
    /// regardless of `conditions.allowsUnmappedSpace`, and navigation clearance minima apply.
    public func route(from start: ElevatedFloorLocation, to destinationID: UUID,
                      conditions: RouteConditions = RoutePreference.stepFree.conditions(),
                      unavailableConnectors: Set<String> = [],
                      obstaclesByZone: [String: [SIMD2<Float>]] = [:]) -> ElevatedFloorRoute? {
        guard let destinationZone = map.zones.first(where: { $0.map.points.contains(where: { $0.id == destinationID }) }),
              let destination = destinationZone.map.points.first(where: { $0.id == destinationID }) else { return nil }
        return route(from: start, to: .init(zoneID: destinationZone.id, position: destination.position),
                     destination: destination, conditions: conditions, unavailableConnectors: unavailableConnectors,
                     obstaclesByZone: obstaclesByZone)
    }

    /// Routes to a selected position on measured floor, without requiring a saved place ID.
    /// Both endpoints keep their explicit zone and elevation; proximity cannot change either.
    public func route(from start: ElevatedFloorLocation, to destination: ElevatedFloorLocation,
                      conditions: RouteConditions = RoutePreference.stepFree.conditions(),
                      destinationName: String? = nil, unavailableConnectors: Set<String> = [],
                      obstaclesByZone: [String: [SIMD2<Float>]] = [:]) -> ElevatedFloorRoute? {
        let point = AccessPoint(kind: .destination, name: destinationName, position: destination.position,
                                source: .manual, confidence: 1)
        return route(from: start, to: destination, destination: point, conditions: conditions,
                     unavailableConnectors: unavailableConnectors, obstaclesByZone: obstaclesByZone)
    }

    private func route(from start: ElevatedFloorLocation, to target: ElevatedFloorLocation,
                       destination: AccessPoint, conditions: RouteConditions,
                       unavailableConnectors: Set<String>, obstaclesByZone: [String: [SIMD2<Float>]]) -> ElevatedFloorRoute? {
        guard map.validLocation(start), map.validLocation(target), destination.name.utf8.count <= 512,
              conditions.minimumClearance.map({ $0.isFinite && $0 >= 0 }) ?? true,
              conditions.obstacles.count <= 10_000, conditions.obstacles.allSatisfy(ElevatedFloorMap.validPoint),
              obstaclesByZone.count <= map.zones.count,
              obstaclesByZone.values.reduce(0, { $0 + $1.count }) <= 10_000,
              obstaclesByZone.allSatisfy({ planners[$0.key] != nil && $0.value.allSatisfy(ElevatedFloorMap.validPoint) }),
              !conditions.unavailable.contains(destination.id) else { return nil }
        if destination.kind == .ramp {
            if conditions.preference == .stepFree && destination.isTooSteep { return nil }
            if conditions.requiresMeasuredRampSlope || conditions.preference == .fastest {
                guard destination.slopeDegrees != nil else { return nil }
            }
        }
        let minimumClearance = max(conditions.preference == .stepFree ? 0.45 : 0.3,
                                   conditions.minimumClearance ?? 0)
        let available = map.connectors.filter { connector in
            guard connector.availability == .available, !unavailableConnectors.contains(connector.id) else { return false }
            if connector.kind == .ramp {
                guard let slope = connector.slopeDegrees,
                      conditions.preference != .stepFree || slope <= AccessPoint.maximumRampSlope else { return false }
            }
            if conditions.preference == .stepFree {
                guard connector.kind != .stairs, connector.stepFree == true,
                      let width = connector.minimumClearWidthMeters, width >= 2 * minimumClearance else { return false }
            } else if let width = connector.minimumClearWidthMeters, width < 2 * minimumClearance { return false }
            return true
        }
        var locations = [start, target]
        var transitions: [Int: [(to: Int, value: ElevatedFloorTransition)]] = [:]
        for connector in available {
            let from = locations.count, to = from + 1
            locations.append(contentsOf: [connector.from, connector.to])
            transitions[from, default: []].append((to, ElevatedFloorTransition(
                connectorID: connector.id, kind: connector.kind, from: connector.from, to: connector.to,
                estimatedSeconds: connector.estimatedSeconds, slopeDegrees: connector.slopeDegrees)))
            if connector.bidirectional {
                transitions[to, default: []].append((from, ElevatedFloorTransition(
                    connectorID: connector.id, kind: connector.kind, from: connector.to, to: connector.from,
                    estimatedSeconds: connector.estimatedSeconds, slopeDegrees: connector.slopeDegrees)))
            }
        }
        var zoneGrids: [String: [(level: Int, grid: OccupancyGrid)]] = [:]
        for zone in map.zones {
            let obstacles = (obstaclesByZone[zone.id] ?? []) + (zone.id == start.zoneID ? conditions.obstacles : [])
            zoneGrids[zone.id] = planners[zone.id]!.grids.enumerated().compactMap { level, grid in
                guard grid.clearance >= minimumClearance else { return nil }
                return (level, obstacles.isEmpty ? grid : grid.blocking(obstacles, radius: RoutePlanner.obstacleRadius))
            }
        }

        // Small connector graph, expanded lazily. Each grid search serves every landing in
        // its zone, avoiding a full grid search for every pair of landings.
        var costs = [Double](repeating: .infinity, count: locations.count)
        var visited = [Bool](repeating: false, count: locations.count)
        var parents: [Int: (from: Int, segment: ElevatedFloorRouteSegment)] = [:]
        costs[0] = 0
        while let current = locations.indices.filter({ !visited[$0] && costs[$0].isFinite }).min(by: { costs[$0] < costs[$1] }) {
            if current == 1 { break }
            visited[current] = true
            func relax(_ next: Int, seconds: Double, segment: ElevatedFloorRouteSegment) {
                let cost = costs[current] + seconds
                guard !visited[next], cost < costs[next] else { return }
                costs[next] = cost
                parents[next] = (current, segment)
            }
            let location = locations[current]
            let grids = zoneGrids[location.zoneID] ?? []
            // A transition needs a clear, measured landing on BOTH sides even when its
            // endpoint is immediately another connector at the same x/z position.
            let currentIsClear = grids.contains { strictIndex(for: location.floorPoint, on: $0.grid) != nil }
            if currentIsClear {
                for transition in transitions[current] ?? [] {
                    let next = locations[transition.to]
                    guard (zoneGrids[next.zoneID] ?? []).contains(where: {
                        strictIndex(for: next.floorPoint, on: $0.grid) != nil
                    }) else { continue }
                    relax(transition.to, seconds: transition.value.estimatedSeconds, segment: .transition(transition.value))
                }
            }
            var bestSurfaces: [Int: ElevatedFloorSurfaceRoute] = [:]
            for (level, grid) in grids {
                guard let startIndex = strictIndex(for: location.floorPoint, on: grid) else { continue }
                let search = grid.search(from: startIndex)
                for next in locations.indices where !visited[next] && next != current && locations[next].zoneID == location.zoneID {
                    guard let goal = strictIndex(for: locations[next].floorPoint, on: grid), search.cost[goal].isFinite else { continue }
                    let target = next == 1 ? destination : AccessPoint(kind: .destination,
                        position: locations[next].position, source: .manual, confidence: 1)
                    let points = grid.smooth([location.floorPoint] + grid.path(to: goal, parents: search.parent).map(grid.center(of:))
                                            + [locations[next].floorPoint])
                    guard zip(points, points.dropFirst()).allSatisfy({ grid.lineOfSight($0, $1) }) else { continue }
                    let route = Route(destination: target, waypoints: points, length: Polyline.length(of: points),
                                      clearance: grid.clearance, level: level, goalIndex: goal, preference: conditions.preference,
                                      requiredClearance: minimumClearance,
                                      requiresMeasuredRampSlope: conditions.requiresMeasuredRampSlope)
                    let surface = ElevatedFloorSurfaceRoute(zoneID: location.zoneID,
                        elevation: planners[location.zoneID]!.map.floorY, route: route)
                    if let existing = bestSurfaces[next] {
                        if conditions.preference == .fastest && route.length < existing.route.length { bestSurfaces[next] = surface }
                    } else { bestSurfaces[next] = surface }
                }
            }
            for (next, surface) in bestSurfaces { relax(next, seconds: surface.route.estimatedSeconds, segment: .surface(surface)) }
        }
        guard costs[1].isFinite else { return nil }
        var segments: [ElevatedFloorRouteSegment] = []
        var index = 1
        while index != 0 {
            guard let parent = parents[index] else { return nil }
            segments.append(parent.segment)
            index = parent.from
        }
        return ElevatedFloorRoute(displayFloor: map.displayFloor, destination: destination,
            destinationZoneID: target.zoneID, preference: conditions.preference, segments: segments.reversed())
    }

    /// Ordinary destinations may snap 1.5 m in RoutePlanner. A landing must already be
    /// on clear floor, with a visible connection to a nearby cell; snapping through walls
    /// or onto disconnected measured islands would invent a usable connector.
    private func strictIndex(for point: SIMD2<Float>, on grid: OccupancyGrid) -> Int? {
        guard let containing = grid.index(containing: point), !grid.isBlocked(containing) else { return nil }
        return grid.closestIndex(to: point, within: grid.cellSize * 1.5) {
            !grid.isBlocked($0) && grid.lineOfSight(point, grid.center(of: $0))
        }
    }
}
