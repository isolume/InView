import simd

/// A top-down grid of the scanned floor. Blocked cells are anywhere a wheelchair can't be:
/// walls, furniture, stairs, and a clearance margin around all of them.
public struct OccupancyGrid: Sendable {
    /// ADA minimum clear width for a doorway (32 in). Narrower doors stay closed to routing.
    public static let minimumDoorWidth: Float = 0.81

    let shape: GridShape
    /// Distance the route keeps from any obstacle.
    public let clearance: Float
    let blocked: [Bool]
    /// Cells outside measured floor where no wall or obstacle was seen. They stay blocked
    /// unless the grid is opened with `allowingUnmapped()`, and then cost more to cross.
    let unmapped: [Bool]

    public var origin: SIMD2<Float> { shape.origin }
    public var cellSize: Float { shape.cellSize }
    public var width: Int { shape.width }
    public var height: Int { shape.height }

    public init(map: VenueMap, clearance: Float, cellSize: Float = 0.1, padding: Float = 1.5) {
        let floorFootprints = map.footprints.filter { $0.kind == .floor }
        let floors = floorFootprints.compactMap { MeasuredFloor($0, elevation: map.floorY) }
        // The scan's starting point at the origin is always on the map.
        var lower = SIMD2<Float>(repeating: 0)
        var upper = SIMD2<Float>(repeating: 0)
        let bounds = map.footprints.filter { $0.kind != .floor }.flatMap(\.corners)
            + floors.flatMap(\.corners) + map.points.map(\.floorPoint)
        for point in bounds where point.x.isFinite && point.y.isFinite {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        lower -= padding
        upper += padding
        let shape = GridShape(
            origin: lower,
            cellSize: cellSize,
            width: max(1, Int(((upper.x - lower.x) / cellSize).rounded(.up))),
            height: max(1, Int(((upper.y - lower.y) / cellSize).rounded(.up)))
        )

        var hard = [Bool](repeating: false, count: shape.count)
        for footprint in map.footprints where footprint.kind.blocksWheelchairs {
            // Grow by half a cell so thin walls rasterize as solid lines.
            shape.fill(&hard, footprint: footprint, size: footprint.size, grow: cellSize / 2, value: true)
        }
        let doorways = map.footprints.filter { $0.kind.isPassage && $0.size.x >= Self.minimumDoorWidth }
        for door in doorways {
            // Cut through the full wall, even when RoomPlan places the door slightly off the wall line.
            let cut = SIMD2(door.size.x, door.size.y + 0.4)
            shape.fill(&hard, footprint: door, size: cut, grow: 0, value: false)
        }

        var inflated = shape.inflate(hard, radius: clearance)
        for door in doorways {
            // Clearance would close any doorway narrower than twice the margin, so reopen a lane through each one.
            let lane = SIMD2(max(door.size.x - 0.3, cellSize * 3), door.size.y + 2 * clearance + 0.4)
            shape.fill(&inflated, footprint: door, size: lane, grow: 0, value: false)
        }

        var unmapped = [Bool](repeating: false, count: shape.count)
        if !floorFootprints.isEmpty || map.requiresMeasuredFloorCoverage == true {
            // A point or doorway outside a measured floor must not create walkable space.
            // Rasterize each observed polygon only within its bounds, preserving concave
            // gaps and disconnected islands. Apply this after doorway lanes are reopened.
            var observed = [Bool](repeating: false, count: shape.count)
            for floor in floors { shape.fill(&observed, floor: floor) }
            for index in inflated.indices where !observed[index] {
                unmapped[index] = !inflated[index]
                inflated[index] = true
            }
        }

        self.shape = shape
        self.clearance = clearance
        self.blocked = inflated
        self.unmapped = unmapped
    }

    private init(shape: GridShape, clearance: Float, blocked: [Bool], unmapped: [Bool]) {
        self.shape = shape
        self.clearance = clearance
        self.blocked = blocked
        self.unmapped = unmapped
    }

    /// A copy that may also cross free space outside measured floor, where a scan saw no wall
    /// or obstacle but didn't record the floor, such as a hallway walked past. Searches prefer
    /// measured floor, and routes report how far they leave it.
    func allowingUnmapped() -> OccupancyGrid {
        var cells = blocked
        for index in cells.indices where unmapped[index] { cells[index] = false }
        return OccupancyGrid(shape: shape, clearance: clearance, blocked: cells, unmapped: unmapped)
    }

    public func isUnmapped(_ index: Int) -> Bool { unmapped[index] && !blocked[index] }

    /// A copy with round obstacles added, padded by this grid's clearance like everything else.
    func blocking(_ obstacles: [SIMD2<Float>], radius: Float) -> OccupancyGrid {
        let reach = radius + clearance
        var cells = blocked
        for obstacle in obstacles {
            let disc = Footprint(kind: .obstacle, center: obstacle, size: SIMD2(repeating: 2 * reach), yaw: 0)
            shape.fill(&cells, footprint: disc, size: disc.size, grow: 0, value: true) { simd_distance($0, obstacle) <= reach }
        }
        return OccupancyGrid(shape: shape, clearance: clearance, blocked: cells, unmapped: unmapped)
    }

    public func isBlocked(_ index: Int) -> Bool { blocked[index] }

    public func center(of index: Int) -> SIMD2<Float> {
        shape.center(x: index % width, y: index / width)
    }

    public func index(containing point: SIMD2<Float>) -> Int? {
        let cell = (point - origin) / cellSize
        let x = Int(cell.x.rounded(.down)), y = Int(cell.y.rounded(.down))
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return y * width + x
    }

    /// The closest cell to `point` that passes `accept`, within `radius` meters.
    func closestIndex(to point: SIMD2<Float>, within radius: Float, where accept: (Int) -> Bool) -> Int? {
        let clamped = simd_clamp(point, origin, origin + SIMD2(Float(width), Float(height)) * cellSize - 1e-3)
        guard let middle = index(containing: clamped) else { return nil }
        let cx = middle % width, cy = middle / width
        let reach = Int((radius / cellSize).rounded(.up))
        var best: (index: Int, distance: Float)?
        for y in max(0, cy - reach)...min(height - 1, cy + reach) {
            for x in max(0, cx - reach)...min(width - 1, cx + reach) {
                let index = y * width + x
                let distance = simd_distance(shape.center(x: x, y: y), point)
                guard distance <= radius, accept(index) else { continue }
                if best == nil || distance < best!.distance { best = (index, distance) }
            }
        }
        return best?.index
    }

    public func nearestFreeIndex(to point: SIMD2<Float>, within radius: Float) -> Int? {
        closestIndex(to: point, within: radius) { !blocked[$0] }
    }
}

/// Validated floor outlines at the routing level. An invalid or unmeasured outline
/// contributes no free space; maps with no floor footprints retain legacy routing.
private struct MeasuredFloor {
    let corners: [SIMD2<Float>]
    let lower: SIMD2<Float>
    let upper: SIMD2<Float>

    init?(_ footprint: Footprint, elevation: Float) {
        guard elevation.isFinite, let bottom = footprint.bottom, bottom.isFinite,
              abs(bottom - elevation) <= 0.35 else { return nil }
        if footprint.polygon == nil {
            guard footprint.center.x.isFinite, footprint.center.y.isFinite,
                  footprint.size.x.isFinite, footprint.size.y.isFinite,
                  footprint.size.x > 0, footprint.size.y > 0, footprint.yaw.isFinite else { return nil }
        }
        var points = footprint.polygon ?? footprint.corners
        guard points.count <= 512, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        if points.first == points.last { points.removeLast() }
        var ring: [SIMD2<Float>] = []
        for point in points where ring.last != point { ring.append(point) }
        guard ring.count >= 3 else { return nil }
        let origin = ring[0]
        let translated = ring.map { SIMD2<Double>(Double($0.x) - Double(origin.x), Double($0.y) - Double(origin.y)) }
        let area = translated.indices.reduce(0.0) { sum, index in
            sum + Self.cross(translated[index], translated[(index + 1) % translated.count])
        }
        guard abs(area) > 1e-6 else { return nil }
        // Nonadjacent edges may not intersect: accepting a malformed ring would turn
        // its self-overlapping lobes into apparently known floor.
        for a in translated.indices {
            let aNext = (a + 1) % translated.count
            for b in (a + 1)..<translated.count {
                let bNext = (b + 1) % translated.count
                if aNext == b || bNext == a { continue }
                guard !Self.intersects(translated[a], translated[aNext], translated[b], translated[bNext]) else { return nil }
            }
        }
        corners = ring
        lower = ring.reduce(origin) { simd_min($0, $1) }
        upper = ring.reduce(origin) { simd_max($0, $1) }
    }

    func contains(_ point: SIMD2<Float>) -> Bool {
        let p = SIMD2<Double>(Double(point.x), Double(point.y))
        var inside = false
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            let a = SIMD2<Double>(Double(corners[index].x), Double(corners[index].y))
            let b = SIMD2<Double>(Double(next.x), Double(next.y))
            if Self.onSegment(p, a, b) { return true }
            if (a.y > p.y) != (b.y > p.y),
               p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) { inside.toggle() }
        }
        return inside
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

    private static func onSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
        let edge = b - a
        let tolerance = 1e-8 * max(1, simd_length(edge))
        return abs(cross(edge, p - a)) <= tolerance
            && p.x >= min(a.x, b.x) - 1e-8 && p.x <= max(a.x, b.x) + 1e-8
            && p.y >= min(a.y, b.y) - 1e-8 && p.y <= max(a.y, b.y) + 1e-8
    }

    private static func intersects(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
        if onSegment(c, a, b) || onSegment(d, a, b) || onSegment(a, c, d) || onSegment(b, c, d) { return true }
        let abC = cross(b - a, c - a), abD = cross(b - a, d - a)
        let cdA = cross(d - c, a - c), cdB = cross(d - c, b - c)
        return (abC > 0) != (abD > 0) && (cdA > 0) != (cdB > 0)
    }
}

/// Grid geometry: where cells sit on the floor.
struct GridShape: Sendable {
    let origin: SIMD2<Float>
    let cellSize: Float
    let width: Int
    let height: Int

    var count: Int { width * height }

    func center(x: Int, y: Int) -> SIMD2<Float> {
        origin + (SIMD2(Float(x), Float(y)) + 0.5) * cellSize
    }

    fileprivate func fill(_ cells: inout [Bool], floor: MeasuredFloor) {
        let low = (floor.lower - origin) / cellSize
        let high = (floor.upper - origin) / cellSize
        let x0 = max(0, Int(low.x.rounded(.down))), x1 = min(width - 1, Int(high.x.rounded(.up)))
        let y0 = max(0, Int(low.y.rounded(.down))), y1 = min(height - 1, Int(high.y.rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 where !cells[y * width + x] {
                if floor.contains(center(x: x, y: y)) { cells[y * width + x] = true }
            }
        }
    }

    /// Sets every cell whose center lies inside the footprint, resized to `size` and grown by `grow`,
    /// and that also passes `include`.
    func fill(
        _ cells: inout [Bool],
        footprint: Footprint,
        size: SIMD2<Float>,
        grow: Float,
        value: Bool,
        where include: (SIMD2<Float>) -> Bool = { _ in true }
    ) {
        let half = size / 2 + grow
        let c = abs(cos(footprint.yaw)), s = abs(sin(footprint.yaw))
        let extent = SIMD2(c * half.x + s * half.y, s * half.x + c * half.y)
        let low = (footprint.center - extent - origin) / cellSize
        let high = (footprint.center + extent - origin) / cellSize
        let x0 = max(0, Int(low.x.rounded(.down))), x1 = min(width - 1, Int(high.x.rounded(.up)))
        let y0 = max(0, Int(low.y.rounded(.down))), y1 = min(height - 1, Int(high.y.rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let point = center(x: x, y: y)
                let local = footprint.local(point)
                if abs(local.x) <= half.x, abs(local.y) <= half.y, include(point) {
                    cells[y * width + x] = value
                }
            }
        }
    }

    /// Blocks every cell within `radius` of a blocked cell.
    func inflate(_ cells: [Bool], radius: Float) -> [Bool] {
        let reach = radius / cellSize
        let r = Int(reach.rounded(.up))
        guard r > 0 else { return cells }
        var offsets: [(dx: Int, dy: Int)] = []
        for dy in -r...r {
            for dx in -r...r where Float(dx * dx + dy * dy) <= reach * reach {
                offsets.append((dx, dy))
            }
        }
        var result = cells
        for y in 0..<height {
            for x in 0..<width where cells[y * width + x] {
                for (dx, dy) in offsets {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    result[ny * width + nx] = true
                }
            }
        }
        return result
    }
}
