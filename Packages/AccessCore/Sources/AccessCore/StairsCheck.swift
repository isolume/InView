import Foundation
import simd

/// Verifies visible repeated treads/risers, not merely a sloping envelope. A steep smooth ramp
/// must not become stairs. Incomplete/sparse evidence remains for human review.
public enum StairsCheck {
    public enum Verdict: Equatable, Sendable { case stairs, notStairs, inconclusive }

    public struct Measurement: Equatable, Sendable {
        public var minimum: SIMD3<Float>
        public var maximum: SIMD3<Float>
        public var facing: SIMD2<Float>
        public var center: SIMD2<Float>
        public var width: Float
        public var run: Float
        public var rise: Float
        public var treadCount: Int
        public var medianRiser: Float
        public var medianTread: Float

        /// Bounds cover sampled treads only, not the hidden remainder of a flight.
        public func footprint(id: UUID? = nil) -> Footprint? {
            guard width >= 0.2, run >= 0.25 else { return nil }
            return Footprint(kind: .stairs, center: center, size: SIMD2(width, run),
                             yaw: atan2(-facing.x, facing.y), bottom: minimum.y,
                             height: maximum.y - minimum.y, id: id)
        }
    }
    public struct Assessment: Sendable {
        public var verdict: Verdict
        public var measurement: Measurement?
        public init(verdict: Verdict, measurement: Measurement? = nil) {
            self.verdict = verdict; self.measurement = measurement
        }
    }

    public static func classify(_ samples: [SIMD3<Float>], viewer: SIMD3<Float>) -> Verdict {
        assess(samples, viewer: viewer).verdict
    }

    public static func assess(_ samples: [SIMD3<Float>], viewer: SIMD3<Float>) -> Assessment {
        func result(_ verdict: Verdict) -> Assessment { Assessment(verdict: verdict, measurement: nil) }
        let points = Array(samples.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }.prefix(2048))
        guard points.count >= 6, viewer.x.isFinite, viewer.y.isFinite, viewer.z.isFinite else { return result(.inconclusive) }
        let center = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let away = SIMD2(center.x - viewer.x, center.z - viewer.z)
        guard simd_length(away) > 0.1 else { return result(.inconclusive) }
        let axis = simd_normalize(away), across = SIMD2(-axis.y, axis.x)
        let runs = points.map { simd_dot(SIMD2($0.x, $0.z), axis) }
        let heights = points.map(\.y)
        let run = runs.max()! - runs.min()!, rise = heights.max()! - heights.min()!
        guard run >= 0.25, rise >= 0.12 else { return result(.notStairs) }
        let meanRun = runs.reduce(0, +) / Float(runs.count)
        let meanY = heights.reduce(0, +) / Float(heights.count)
        var covariance: Float = 0, runVariance: Float = 0, heightVariance: Float = 0
        for (u, y) in zip(runs, heights) {
            covariance += (u - meanRun) * (y - meanY)
            runVariance += (u - meanRun) * (u - meanRun)
            heightVariance += (y - meanY) * (y - meanY)
        }
        guard runVariance > 0, heightVariance > 0 else { return result(.notStairs) }
        let correlation = covariance / sqrt(runVariance * heightVariance)
        let incline = atan(abs(covariance / runVariance)) * 180 / .pi
        guard abs(correlation) >= 0.8, (18...58).contains(incline) else { return result(.notStairs) }

        // Group by height, requiring an actual flat patch along the flight, not duplicate
        // samples across its width. Riser-only returns and smooth inclines have no plateaus.
        var groups: [[SIMD3<Float>]] = []
        for point in points.sorted(by: { $0.y < $1.y }) {
            if let last = groups.last, point.y - last[0].y <= 0.035 {
                groups[groups.count - 1].append(point)
            } else { groups.append([point]) }
        }
        let treads = groups.filter { group in
            let u = group.map { simd_dot(SIMD2($0.x, $0.z), axis) }
            return group.count >= 2 && u.max()! - u.min()! >= 0.08
        }.sorted {
            let a = $0.map { simd_dot(SIMD2($0.x, $0.z), axis) }.reduce(0, +) / Float($0.count)
            let b = $1.map { simd_dot(SIMD2($0.x, $0.z), axis) }.reduce(0, +) / Float($1.count)
            return a < b
        }
        guard treads.count >= 3 else { return result(.inconclusive) }
        let centers = treads.map { $0.reduce(SIMD3<Float>.zero, +) / Float($0.count) }
        var risers: [Float] = [], pitches: [Float] = []
        let sign: Float = covariance >= 0 ? 1 : -1
        for (a, b) in zip(centers, centers.dropFirst()) {
            let riser = (b.y - a.y) * sign
            let pitch = simd_dot(SIMD2(b.x - a.x, b.z - a.z), axis)
            guard (0.09...0.24).contains(riser), (0.16...0.5).contains(pitch) else { return result(.inconclusive) }
            risers.append(riser); pitches.append(pitch)
        }
        let measured = treads.flatMap { $0 }
        let lower = measured.reduce(measured[0], simd_min), upper = measured.reduce(measured[0], simd_max)
        let u = measured.map { simd_dot(SIMD2($0.x, $0.z), axis) }
        let v = measured.map { simd_dot(SIMD2($0.x, $0.z), across) }
        let measurement = Measurement(minimum: lower, maximum: upper, facing: axis * sign,
            center: axis * ((u.min()! + u.max()!) / 2) + across * ((v.min()! + v.max()!) / 2),
            width: v.max()! - v.min()!, run: u.max()! - u.min()!, rise: upper.y - lower.y,
            treadCount: treads.count, medianRiser: risers.sorted()[risers.count / 2],
            medianTread: pitches.sorted()[pitches.count / 2])
        return Assessment(verdict: .stairs, measurement: measurement)
    }
}
