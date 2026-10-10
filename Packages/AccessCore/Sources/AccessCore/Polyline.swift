import simd

/// Helpers for routes drawn as connected floor points.
public enum Polyline {
    public static func length(of points: [SIMD2<Float>]) -> Float {
        zip(points, points.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
    }

    /// The first `distance` meters of the polyline.
    public static func prefix(of points: [SIMD2<Float>], distance: Float) -> [SIMD2<Float>] {
        guard let first = points.first else { return [] }
        var result = [first]
        var remaining = distance
        for (a, b) in zip(points, points.dropFirst()) {
            let segment = simd_distance(a, b)
            if segment >= remaining {
                if segment > 0 { result.append(a + (b - a) * (remaining / segment)) }
                return result
            }
            result.append(b)
            remaining -= segment
        }
        return result
    }

    /// Shortest distance from a point to the polyline.
    public static func distance(from point: SIMD2<Float>, to points: [SIMD2<Float>]) -> Float {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return simd_distance(point, first) }
        return zip(points, points.dropFirst()).map { segmentDistance(point, $0, $1) }.min() ?? .infinity
    }

    static func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_distance(p, a) }
        let t = simd_clamp(simd_dot(p - a, ab) / lengthSquared, 0, 1)
        return simd_distance(p, a + ab * t)
    }
}
