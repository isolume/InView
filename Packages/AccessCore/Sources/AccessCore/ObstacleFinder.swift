import simd

/// Finds things blocking the route ahead in LiDAR depth points: chairs, carts, signs that weren't there
/// when the floor was scanned.
public enum ObstacleFinder {
    public struct Settings: Sendable {
        /// How far either side of the route counts as in the way.
        public var corridor: Float = 0.45
        /// How far along the route to look.
        public var lookahead: Float = 4
        /// Ignore points this close to the user: their own feet, footrests, wheels.
        public var ignoreNear: Float = 0.8
        /// Height band above the floor that can block a wheelchair.
        public var minimumHeight: Float = 0.1
        public var maximumHeight: Float = 1.2
        /// How far below the floor estimate ground still counts as the ground an obstacle stands on.
        public var maximumDescent: Float = 1.0
        public var cellSize: Float = 0.1
        public var minimumPointsPerCell = 6
        /// Real obstacles stand up; a ramp or a floor bump spreads flat. Cells need at least this much vertical extent.
        public var minimumHeightSpread: Float = 0.2

        public init() {}
    }

    private struct Cell: Hashable {
        var x: Int
        var z: Int
    }

    /// - Returns: Floor positions (x, z) of each separate obstacle on the route ahead.
    public static func obstacles(
        in points: [SIMD3<Float>],
        along route: [SIMD2<Float>],
        floorY: Float,
        settings: Settings = Settings()
    ) -> [SIMD2<Float>] {
        guard let start = route.first else { return [] }
        let ahead = Polyline.prefix(of: route, distance: settings.lookahead)

        // Obstacles are measured above the ground *they stand on*: the floor estimate, or lower where
        // the scan sees lower ground (the foot of a ramp, a sunken area). The estimate alone would make
        // a chair at the bottom of a ramp look like it sits below the height band.
        func cell(of floor: SIMD2<Float>) -> Cell {
            Cell(x: Int((floor.x / settings.cellSize).rounded(.down)), z: Int((floor.y / settings.cellSize).rounded(.down)))
        }
        let deepest = floorY - settings.maximumDescent
        var inCorridor: [(point: SIMD3<Float>, cell: Cell)] = []
        var lowest: [Cell: Float] = [:]
        for point in points {
            guard point.y > deepest, point.y < floorY + settings.maximumHeight else { continue }
            let floor = SIMD2(point.x, point.z)
            guard simd_distance(floor, start) > settings.ignoreNear,
                  Polyline.distance(from: floor, to: ahead) < settings.corridor else { continue }
            let at = cell(of: floor)
            inCorridor.append((point, at))
            if point.y < floorY + settings.minimumHeight { lowest[at] = min(lowest[at] ?? point.y, point.y) }
        }
        func groundHeight(at cell: Cell) -> Float {
            var ground = floorY
            for dx in -1...1 {
                for dz in -1...1 {
                    if let low = lowest[Cell(x: cell.x + dx, z: cell.z + dz)] { ground = min(ground, low) }
                }
            }
            return ground
        }

        var stats: [Cell: (count: Int, low: Float, high: Float)] = [:]
        for (point, at) in inCorridor {
            let height = point.y - groundHeight(at: at)
            guard height > settings.minimumHeight, height < settings.maximumHeight else { continue }
            let current = stats[at] ?? (0, height, height)
            stats[at] = (current.count + 1, min(current.low, height), max(current.high, height))
        }

        let solid = Set(stats.filter {
            $0.value.count >= settings.minimumPointsPerCell && $0.value.high - $0.value.low >= settings.minimumHeightSpread
        }.keys)

        // Merge touching cells so one chair becomes one obstacle.
        var unvisited = solid
        var centers: [SIMD2<Float>] = []
        while let seed = unvisited.popFirst() {
            var cluster = [seed]
            var frontier = [seed]
            while let cell = frontier.popLast() {
                for dx in -1...1 {
                    for dz in -1...1 {
                        let neighbor = Cell(x: cell.x + dx, z: cell.z + dz)
                        if unvisited.remove(neighbor) != nil {
                            cluster.append(neighbor)
                            frontier.append(neighbor)
                        }
                    }
                }
            }
            let sum = cluster.reduce(SIMD2<Float>.zero) { $0 + SIMD2(Float($1.x), Float($1.z)) }
            centers.append((sum / Float(cluster.count) + 0.5) * settings.cellSize)
        }
        return centers
    }
}
