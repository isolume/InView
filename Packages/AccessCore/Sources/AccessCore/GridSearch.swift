import HeapModule
import simd

extension OccupancyGrid {
    struct SearchResult {
        /// Path cost from the start to each cell, in cells. Infinite where unreachable.
        var cost: [Float]
        var parent: [Int32]
    }

    private struct Entry: Comparable {
        var priority: Float
        var cost: Float
        var index: Int

        static func < (lhs: Entry, rhs: Entry) -> Bool { lhs.priority < rhs.priority }
    }

    private static let diagonalStep = Float(2).squareRoot()
    /// Crossing unmapped space costs this much more than measured floor, so routes only leave
    /// the scan where it saves a long way round or there is no other way.
    static let unmappedStepCost: Float = 3
    private static let neighborOffsets = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]

    /// Dijkstra over free cells, or A* when a goal is given. Moves are 8-connected and never
    /// cut across a blocked corner.
    func search(from start: Int, to goal: Int? = nil) -> SearchResult {
        // Existing synchronous callers always finish a search. Background audits use the
        // throwing overload so cancellation never looks like an unreachable destination.
        try! search(from: start, to: goal, storingParents: true, isCancelled: { false })
    }

    /// Audits only need costs, and can avoid retaining a parent index for every floor cell.
    func search(from start: Int, to goal: Int? = nil, storingParents: Bool,
                isCancelled: () -> Bool) throws -> SearchResult {
        guard !isCancelled() else { throw CancellationError() }
        var cost = [Float](repeating: .infinity, count: blocked.count)
        var parent = storingParents ? [Int32](repeating: -1, count: blocked.count) : []
        var open = Heap<Entry>()
        let goalX = goal.map { $0 % width }, goalY = goal.map { $0 / width }

        func heuristic(_ index: Int) -> Float {
            guard let goalX, let goalY else { return 0 }
            let dx = Float(abs(index % width - goalX)), dy = Float(abs(index / width - goalY))
            return max(dx, dy) + (Self.diagonalStep - 1) * min(dx, dy)
        }

        cost[start] = 0
        open.insert(Entry(priority: heuristic(start), cost: 0, index: start))
        var iterations = 0
        while let entry = open.popMin() {
            // Bound cancellation latency without testing it for every neighbor.
            if iterations % 256 == 0, isCancelled() { throw CancellationError() }
            iterations += 1
            let index = entry.index
            guard entry.cost <= cost[index] else { continue }
            if index == goal { break }
            let x = index % width, y = index / width
            for (dx, dy) in Self.neighborOffsets {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let neighbor = ny * width + nx
                guard !blocked[neighbor] else { continue }
                let diagonal = dx != 0 && dy != 0
                if diagonal && (blocked[y * width + nx] || blocked[ny * width + x]) { continue }
                let next = entry.cost + (diagonal ? Self.diagonalStep : 1) * (unmapped[neighbor] ? Self.unmappedStepCost : 1)
                if next < cost[neighbor] {
                    cost[neighbor] = next
                    if storingParents { parent[neighbor] = Int32(index) }
                    open.insert(Entry(priority: next + heuristic(neighbor), cost: next, index: neighbor))
                }
            }
        }
        guard !isCancelled() else { throw CancellationError() }
        return SearchResult(cost: cost, parent: parent)
    }

    func path(to goal: Int, parents: [Int32]) -> [Int] {
        var path = [goal]
        var current = goal
        while parents[current] >= 0 {
            current = Int(parents[current])
            path.append(current)
        }
        return path.reversed()
    }

    func lineOfSight(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
        // Promote before subtracting: Float cancellation far from the origin
        // can reverse which cell edge a segment crosses first at a corner.
        let gridOrigin = SIMD2<Double>(Double(origin.x), Double(origin.y))
        let localA = (SIMD2<Double>(Double(a.x), Double(a.y)) - gridOrigin) / Double(cellSize)
        let localB = (SIMD2<Double>(Double(b.x), Double(b.y)) - gridOrigin) / Double(cellSize)
        guard localA.x >= 0, localA.y >= 0, localA.x < Double(width), localA.y < Double(height),
              localB.x >= 0, localB.y >= 0, localB.x < Double(width), localB.y < Double(height),
              let start = index(containing: a), let end = index(containing: b),
              !blocked[start], !blocked[end] else { return false }
        let dx = localB.x - localA.x
        let dy = localB.y - localA.y
        let stepX = dx > 0 ? 1 : dx < 0 ? -1 : 0
        let stepY = dy > 0 ? 1 : dy < 0 ? -1 : 0
        // Use the same precision for traversal cells and crossing times. Float cell
        // lookup can round an endpoint up across a boundary that Double still places
        // just below it, making visibility depend on the direction of travel. Keep
        // the public lookup checks above as an additional conservative endpoint test.
        var x = Int(localA.x.rounded(.down)), y = Int(localA.y.rounded(.down))
        let endX = Int(localB.x.rounded(.down)), endY = Int(localB.y.rounded(.down))
        let deltaX = stepX == 0 ? Double.infinity : abs(1 / dx)
        let deltaY = stepY == 0 ? Double.infinity : abs(1 / dy)
        var nextX = stepX == 0 ? Double.infinity
            : (Double(x + (stepX > 0 ? 1 : 0)) - localA.x) / dx
        var nextY = stepY == 0 ? Double.infinity
            : (Double(y + (stepY > 0 ? 1 : 0)) - localA.y) / dy

        func cellIsFree(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && !blocked[y * width + x]
        }
        let followsVerticalEdge = stepX == 0 && localA.x == localA.x.rounded(.down)
        let followsHorizontalEdge = stepY == 0 && localA.y == localA.y.rounded(.down)
        func isFree(_ x: Int, _ y: Int) -> Bool {
            cellIsFree(x, y)
                && (!followsVerticalEdge || cellIsFree(x - 1, y))
                && (!followsHorizontalEdge || cellIsFree(x, y - 1))
        }
        guard isFree(x, y) else { return false }

        // Visit every cell crossed by the segment. Fixed-distance samples can miss a
        // short crossing near a blocked corner and erase a necessary path waypoint.
        while x != endX || y != endY {
            if abs(nextX - nextY) <= 1e-10 {
                // Touching a corner must obey the same rule as a diagonal search step.
                guard isFree(x + stepX, y), isFree(x, y + stepY) else { return false }
                x += stepX
                y += stepY
                nextX += deltaX
                nextY += deltaY
            } else if nextX < nextY {
                x += stepX
                nextX += deltaX
            } else {
                y += stepY
                nextY += deltaY
            }
            guard isFree(x, y) else { return false }
        }
        return true
    }

    /// Drops waypoints the route can skip in a straight line, so arrows follow natural lines
    /// instead of grid staircases.
    func smooth(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count > 2 else { return points }
        var result = [points[0]]
        var anchor = 0
        while anchor < points.count - 1 {
            var next = anchor + 1
            while next + 1 < points.count, lineOfSight(points[anchor], points[next + 1]) {
                next += 1
            }
            result.append(points[next])
            anchor = next
        }
        return result
    }
}
