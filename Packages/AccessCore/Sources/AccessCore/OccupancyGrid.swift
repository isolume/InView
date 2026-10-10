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

    public var origin: SIMD2<Float> { shape.origin }
    public var cellSize: Float { shape.cellSize }
    public var width: Int { shape.width }
    public var height: Int { shape.height }

    public init(map: VenueMap, clearance: Float, cellSize: Float = 0.1, padding: Float = 1.5) {
        // The scan's starting point at the origin is always on the map.
        var lower = SIMD2<Float>(repeating: 0)
        var upper = SIMD2<Float>(repeating: 0)
        for point in map.footprints.flatMap(\.corners) + map.points.map(\.floorPoint) {
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

        self.shape = shape
        self.clearance = clearance
        self.blocked = inflated
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

    /// Sets every cell whose center lies inside the footprint, resized to `size` and grown by `grow`.
    func fill(_ cells: inout [Bool], footprint: Footprint, size: SIMD2<Float>, grow: Float, value: Bool) {
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
                let local = footprint.local(center(x: x, y: y))
                if abs(local.x) <= half.x, abs(local.y) <= half.y {
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
