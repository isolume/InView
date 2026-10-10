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
    private static let neighborOffsets = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]

    /// Dijkstra over free cells, or A* when a goal is given. Moves are 8-connected and never
    /// cut across a blocked corner.
    func search(from start: Int, to goal: Int? = nil) -> SearchResult {
        var cost = [Float](repeating: .infinity, count: blocked.count)
        var parent = [Int32](repeating: -1, count: blocked.count)
        var open = Heap<Entry>()
        let goalX = goal.map { $0 % width }, goalY = goal.map { $0 / width }

        func heuristic(_ index: Int) -> Float {
            guard let goalX, let goalY else { return 0 }
            let dx = Float(abs(index % width - goalX)), dy = Float(abs(index / width - goalY))
            return max(dx, dy) + (Self.diagonalStep - 1) * min(dx, dy)
        }

        cost[start] = 0
        open.insert(Entry(priority: heuristic(start), cost: 0, index: start))
        while let entry = open.popMin() {
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
                let next = entry.cost + (diagonal ? Self.diagonalStep : 1)
                if next < cost[neighbor] {
                    cost[neighbor] = next
                    parent[neighbor] = Int32(index)
                    open.insert(Entry(priority: next + heuristic(neighbor), cost: next, index: neighbor))
                }
            }
        }
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
        let steps = max(1, Int((simd_distance(a, b) / (cellSize / 2)).rounded(.up)))
        for step in 0...steps {
            let point = simd_mix(a, b, SIMD2(repeating: Float(step) / Float(steps)))
            guard let index = index(containing: point), !blocked[index] else { return false }
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
