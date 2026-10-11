import Foundation
import simd

/// Conservative measurements from ARKit planes, independent of RoomPlan's room inference.
public enum ObservedSurfaceGeometry {
    public enum Classification: Sendable {
        case floor, wall, unclassified, other
    }

    public struct Plane: Sendable {
        public var id: UUID
        public var boundary: [SIMD3<Float>]
        public var normal: SIMD3<Float>
        public var isHorizontal: Bool
        public var classification: Classification

        public init(id: UUID, boundary: [SIMD3<Float>], normal: SIMD3<Float>,
                    isHorizontal: Bool, classification: Classification) {
            self.id = id
            self.boundary = boundary
            self.normal = normal
            self.isHorizontal = isHorizontal
            self.classification = classification
        }
    }

    public static let maximumBoundaryVertices = 128
    public static let maximumFloorExtent: Float = 200
    public static let maximumFloorArea: Float = 5_000
    public static let maximumBarrierExtent: Float = 40
    public static let maximumWallHeight: Float = 6

    /// A horizontal floor must agree with an independently established floor elevation.
    /// Classified walls retain their measured height; unclassified barriers remain conservative.
    public static func footprint(for plane: Plane, floorY: Float) -> Footprint? {
        guard floorY.isFinite, (3...maximumBoundaryVertices).contains(plane.boundary.count),
              plane.boundary.allSatisfy({ point in point.x.isFinite && point.y.isFinite && point.z.isFinite }),
              plane.normal.x.isFinite, plane.normal.y.isFinite, plane.normal.z.isFinite,
              simd_length(plane.normal) > 0.9 else { return nil }
        let normal = simd_normalize(plane.normal)
        let bottom = plane.boundary.map(\.y).min()!
        let top = plane.boundary.map(\.y).max()!
        if plane.isHorizontal {
            guard plane.classification == .floor || plane.classification == .unclassified,
                  abs(normal.y) >= 0.98, top - bottom <= 0.08,
                  abs(bottom - floorY) <= 0.18, abs(top - floorY) <= 0.18 else { return nil }
            let polygon = plane.boundary.map { SIMD2($0.x, $0.z) }
            var result = Footprint(floor: polygon, bottom: (bottom + top) / 2)
            guard result.size.x >= 0.1, result.size.y >= 0.1,
                  result.size.x <= maximumFloorExtent, result.size.y <= maximumFloorExtent,
                  abs(area(polygon)) >= 0.2, abs(area(polygon)) <= maximumFloorArea,
                  isSimple(polygon) else { return nil }
            result.id = plane.id
            return result
        }
        let maximumHeight: Float = plane.classification == .wall ? maximumWallHeight : 1.6
        guard plane.classification == .wall || plane.classification == .unclassified,
              abs(normal.y) <= 0.15, abs(bottom - floorY) <= 0.3,
              top - bottom >= 0.35, top - bottom <= maximumHeight else { return nil }
        let along = simd_normalize(SIMD2(normal.z, -normal.x))
        let across = SIMD2(-along.y, along.x)
        let points = plane.boundary.map { SIMD2($0.x, $0.z) }
        let u = points.map { simd_dot($0, along) }
        let v = points.map { simd_dot($0, across) }
        let lower = u.min()!, upper = u.max()!
        let near = v.min()!, far = v.max()!
        // An unclassified short vertical plane is often a chair, bag or table side.
        // Classified walls can be short; generic barriers need a longer coherent span.
        let minimumLength: Float = plane.classification == .wall ? 0.3 : 1.2
        guard upper - lower >= minimumLength, upper - lower <= maximumBarrierExtent, far - near <= 0.12 else { return nil }
        return Footprint(kind: .wall,
                         center: along * ((lower + upper) / 2) + across * ((near + far) / 2),
                         size: SIMD2(upper - lower, 0.15), yaw: atan2(along.y, along.x),
                         bottom: bottom, height: top - bottom, id: plane.id)
    }

    private static func area(_ polygon: [SIMD2<Float>]) -> Float {
        let origin = polygon[0]
        var result: Float = 0
        for index in polygon.indices {
            let a = polygon[index] - origin, b = polygon[(index + 1) % polygon.count] - origin
            result += a.x * b.y - a.y * b.x
        }
        return result / 2
    }

    /// Reject crossed outlines instead of filling an inferred region across missing floor.
    private static func isSimple(_ polygon: [SIMD2<Float>]) -> Bool {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            let ab = b - a, ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }
        for first in polygon.indices {
            let firstEnd = (first + 1) % polygon.count
            guard simd_distance(polygon[first], polygon[firstEnd]) > 1e-4 else { return false }
            for second in (first + 1)..<polygon.count {
                let secondEnd = (second + 1) % polygon.count
                if firstEnd == second || secondEnd == first { continue }
                let a = polygon[first], b = polygon[firstEnd], c = polygon[second], d = polygon[secondEnd]
                if cross(a, b, c) * cross(a, b, d) < 0,
                   cross(c, d, a) * cross(c, d, b) < 0 { return false }
            }
        }
        return true
    }
}

/// Stores bounded confirmed plane values; growing ARKit geometry is never copied every frame.
/// A removed anchor keeps its last proven surface, while refinements replace provisional outlines.
public struct ObservedSurfaceAccumulator: Sendable {
    public let maximumPlanes: Int
    public let maximumFloors = 64
    public let maximumFloorVertices = 1_024
    public let maximumBarriers = 128
    private struct Observation: Sendable {
        var candidate: Footprint
        var timestamp: TimeInterval
    }
    private var pending: [UUID: Observation] = [:]
    private var confirmed: [UUID: Footprint] = [:]
    private var lastPruneTimestamp: TimeInterval?

    public init(maximumPlanes: Int = 192) {
        self.maximumPlanes = max(0, min(maximumPlanes, 192))
    }

    public var count: Int { confirmed.count }

    public mutating func observe(_ plane: ObservedSurfaceGeometry.Plane, floorY: Float, timestamp: TimeInterval) {
        guard timestamp.isFinite else { return }
        if lastPruneTimestamp.map({ timestamp - $0 >= 1 }) ?? true {
            pending = pending.filter { timestamp - $0.value.timestamp <= 4 }
            lastPruneTimestamp = timestamp
        }
        if let previous = pending[plane.id], timestamp <= previous.timestamp { return }
        guard let footprint = ObservedSurfaceGeometry.footprint(for: plane, floorY: floorY) else {
            pending.removeValue(forKey: plane.id)
            // A live refinement that no longer qualifies contradicts the old measurement.
            // Missing anchors still retain coverage; explicitly invalid ones do not.
            confirmed.removeValue(forKey: plane.id)
            return
        }
        if let saved = confirmed[plane.id], saved.kind != footprint.kind {
            confirmed.removeValue(forKey: plane.id)
        }
        guard pending[plane.id] != nil || confirmed[plane.id] != nil || pending.count < maximumPlanes else { return }
        if let previous = pending[plane.id] {
            guard timestamp > previous.timestamp else { return }
            if timestamp - previous.timestamp >= 0.5,
               timestamp - previous.timestamp <= 4,
               spatiallyConsistent(previous.candidate, footprint),
               fitsBudget(footprint, replacing: plane.id) {
                confirmed[plane.id] = footprint
            }
        }
        pending[plane.id] = Observation(candidate: footprint, timestamp: timestamp)
    }

    /// Missing anchors are intentionally retained. Outputs contain no mutable framework buffers.
    public func snapshot() -> [Footprint] {
        confirmed.sorted { $0.key.uuidString < $1.key.uuidString }.map(\.value)
    }

    /// A confirmed nearby floor can anchor partial walls even if RoomPlan found no floor.
    /// The height check excludes another level visible through a balcony or atrium.
    public func floorElevation(near position: SIMD3<Float>, within range: Float = 12) -> Float? {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              range.isFinite, range >= 0 else { return nil }
        let point = SIMD2(position.x, position.z)
        var best: (distance: Float, elevation: Float)?
        for (_, floor) in confirmed.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where floor.kind == .floor {
            guard let elevation = floor.bottom, (0.6...2).contains(position.y - elevation) else { continue }
            let polygon = floor.corners
            var inside = false
            var distance = Float.greatestFiniteMagnitude
            for index in polygon.indices {
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                let edge = b - a
                let t = simd_clamp(simd_dot(point - a, edge) / simd_length_squared(edge), 0, 1)
                distance = min(distance, simd_distance(point, a + edge * t))
            }
            if inside { distance = 0 }
            guard distance <= range else { continue }
            if best == nil || distance < best!.distance { best = (distance, elevation) }
        }
        return best?.elevation
    }

    private func fitsBudget(_ candidate: Footprint, replacing id: UUID) -> Bool {
        let others = confirmed.filter { $0.key != id }.map(\.value)
        guard others.count < maximumPlanes else { return false }
        let floors = others.filter { $0.kind == .floor }
        if candidate.kind == .floor {
            return floors.count < maximumFloors
                && floors.reduce(candidate.corners.count, { $0 + $1.corners.count }) <= maximumFloorVertices
        }
        return others.count - floors.count < maximumBarriers
    }

    private func spatiallyConsistent(_ first: Footprint, _ second: Footprint) -> Bool {
        guard first.kind == second.kind,
              abs((first.bottom ?? 0) - (second.bottom ?? 0)) <= 0.1 else { return false }
        // A modest extension of a stable plane is allowed; a moved or replaced plane must be
        // observed again at its new position before it changes the saved geometry.
        let change = simd_distance(first.center, second.center)
        let growth = simd_length(second.size - first.size) / 2
        return growth <= 2 && change <= max(0.35, growth + 0.15)
    }
}
