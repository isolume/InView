import simd

/// Measures how steep a surface is from LiDAR samples on it.
public enum SurfaceFit {
    /// Each refit drops samples further than this from the previous plane (a railing, a wall edge, the floor past the ramp).
    static let outlierDistances: [Double] = [0.1, 0.05, 0.03]
    static let minimumSamples = 8

    /// Fits a plane to the samples and returns its tilt from horizontal in degrees,
    /// or nil when there are too few consistent samples.
    public static func slopeDegrees(of samples: [SIMD3<Float>]) -> Float? {
        var points = samples.map { SIMD3<Double>($0) }
        guard var plane = fitPlane(points) else { return nil }
        for distance in outlierDistances {
            points = points.filter { abs(plane.residual($0)) < distance }
            guard let refit = fitPlane(points) else { return nil }
            plane = refit
        }
        return Float(atan(plane.gradient) * 180 / .pi)
    }

    /// y = a·x + b·z + c, fitted around the samples' centroid for numerical stability.
    private struct Plane {
        var a: Double
        var b: Double
        var c: Double
        var centroid: SIMD3<Double>

        var gradient: Double { (a * a + b * b).squareRoot() }

        func residual(_ point: SIMD3<Double>) -> Double {
            let p = point - centroid
            return p.y - (a * p.x + b * p.z + c)
        }
    }

    private static func fitPlane(_ points: [SIMD3<Double>]) -> Plane? {
        guard points.count >= minimumSamples else { return nil }
        let centroid = points.reduce(SIMD3<Double>.zero, +) / Double(points.count)
        var normal = simd_double3x3()
        var rhs = SIMD3<Double>.zero
        for point in points {
            let p = point - centroid
            let row = SIMD3(p.x, p.z, 1)
            normal += simd_double3x3(rows: [row * row.x, row * row.y, row * row.z])
            rhs += row * p.y
        }
        guard abs(normal.determinant) > 1e-9 else { return nil }
        let solution = normal.inverse * rhs
        return Plane(a: solution.x, b: solution.y, c: solution.z, centroid: centroid)
    }
}
