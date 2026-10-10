import Foundation
import simd

/// Nearby scan annotations, indexed by small world-space cells. A growing building need not be
/// searched in full for each camera overlay refresh or repeated vision detection.
public struct ScanSightingIndex {
    private struct Cell: Hashable {
        let x: Int
        let z: Int
    }

    private let cellSize: Float = 4
    private var positions: [UUID: SIMD3<Float>] = [:]
    private var buckets: [Cell: Set<UUID>] = [:]

    public init() {}

    public mutating func update(_ id: UUID, at position: SIMD3<Float>) {
        guard let destination = cell(at: position) else { return }
        if let previous = positions[id], let source = cell(at: previous), source != destination {
            buckets[source]?.remove(id)
            if buckets[source]?.isEmpty == true { buckets.removeValue(forKey: source) }
        }
        positions[id] = position
        buckets[destination, default: []].insert(id)
    }

    /// Only entries in neighboring cells are visited. Height filtering prevents stacked floors from
    /// merging or showing one another's tags; all annotations remain available for map review.
    public func nearby(
        _ position: SIMD3<Float>,
        radius: Float,
        maximumHeightDifference: Float
    ) -> [UUID] {
        guard radius.isFinite, radius >= 0, radius <= 100,
              maximumHeightDifference.isFinite, maximumHeightDifference >= 0,
              let minimum = cell(at: position - SIMD3(radius, 0, radius)),
              let maximum = cell(at: position + SIMD3(radius, 0, radius)) else { return [] }
        var result: [UUID] = []
        let origin = SIMD2(position.x, position.z)
        for x in minimum.x...maximum.x {
            for z in minimum.z...maximum.z {
                guard let ids = buckets[Cell(x: x, z: z)] else { continue }
                for id in ids {
                    guard let candidate = positions[id],
                          abs(candidate.y - position.y) <= maximumHeightDifference,
                          simd_length_squared(SIMD2(candidate.x, candidate.z) - origin) <= radius * radius else { continue }
                    result.append(id)
                }
            }
        }
        return result
    }

    private func cell(at position: SIMD3<Float>) -> Cell? {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              let x = Int(exactly: floor(Double(position.x / cellSize))),
              let z = Int(exactly: floor(Double(position.z / cellSize))) else { return nil }
        return Cell(x: x, z: z)
    }
}
