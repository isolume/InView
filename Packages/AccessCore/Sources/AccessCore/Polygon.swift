import simd

/// Helpers for simple polygons on the floor, as (x, z) corners in order.
public enum Polygon {
    /// Signed area: positive when the corners run counter-clockwise in (x, z).
    public static func signedArea(_ corners: [SIMD2<Float>]) -> Float {
        guard corners.count >= 3 else { return 0 }
        var sum: Float = 0
        for (a, b) in zip(corners, corners.dropFirst() + [corners[0]]) {
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Splits a simple polygon (convex or concave, no self-intersections) into triangles by ear clipping.
    /// Returns corner indices, three per triangle, or an empty array when the polygon is degenerate.
    public static func triangulate(_ corners: [SIMD2<Float>]) -> [Int] {
        guard corners.count >= 3 else { return [] }
        let area = signedArea(corners)
        guard abs(area) > 1e-6 else { return [] }
        // Work counter-clockwise so "convex" has one meaning.
        var remaining = Array(corners.indices)
        if area < 0 { remaining.reverse() }

        var triangles: [Int] = []
        var guardCount = 0
        while remaining.count > 3, guardCount < corners.count * corners.count {
            guardCount += 1
            var clipped = false
            for i in remaining.indices {
                let previous = remaining[(i + remaining.count - 1) % remaining.count]
                let current = remaining[i]
                let next = remaining[(i + 1) % remaining.count]
                let a = corners[previous], b = corners[current], c = corners[next]
                guard cross(b - a, c - b) > 1e-7 else { continue }  // reflex corner, not an ear
                let containsOther = remaining.contains { index in
                    index != previous && index != current && index != next && inside(corners[index], a, b, c)
                }
                if containsOther { continue }
                triangles += [previous, current, next]
                remaining.remove(at: i)
                clipped = true
                break
            }
            // Collinear or otherwise stuck: fan out the rest rather than loop forever.
            if !clipped { break }
        }
        if remaining.count >= 3 {
            for i in 1..<(remaining.count - 1) {
                triangles += [remaining[0], remaining[i], remaining[i + 1]]
            }
        }
        return triangles
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        a.x * b.y - a.y * b.x
    }

    /// Whether `p` lies inside or on triangle abc (counter-clockwise). A corner sitting exactly on an ear's
    /// edge, as the inner corner of an L-shaped room does, still disqualifies the ear.
    private static func inside(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        cross(b - a, p - a) >= -1e-7 && cross(c - b, p - b) >= -1e-7 && cross(a - c, p - c) >= -1e-7
    }
}
