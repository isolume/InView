import simd

/// Checks a vision model's "stairs" claim against LiDAR: a staircase's surface climbs steadily
/// away from the viewer, unlike a flat floor, a ramp, or the vertical face of a wall or cabinet.
public enum StairsCheck {
    public enum Verdict: Equatable, Sendable {
        case stairs
        case notStairs
        /// Too few surface samples to tell either way.
        case inconclusive
    }

    static let minimumSamples = 5
    /// Stairs rise at least this much over the sampled stretch; anything flatter is floor or a ramp.
    static let minimumRise: Float = 0.12
    /// The samples must spread at least this far horizontally; anything narrower is a vertical face.
    static let minimumRun: Float = 0.25
    /// Overall incline of real stairs, in degrees. Building codes put most between about 30° and 40°.
    static let inclineRange: ClosedRange<Float> = 18...58
    /// How well height must follow horizontal distance (|correlation|) for a steady climb.
    static let minimumCorrelation: Float = 0.8

    /// - Parameters:
    ///   - samples: Surface points around where the model said the stairs are.
    ///   - viewer: Where the camera was, to measure distance away from it.
    public static func classify(_ samples: [SIMD3<Float>], viewer: SIMD3<Float>) -> Verdict {
        guard samples.count >= minimumSamples else { return .inconclusive }
        let origin = SIMD2(viewer.x, viewer.z)
        let runs = samples.map { simd_distance(SIMD2($0.x, $0.z), origin) }
        let heights = samples.map(\.y)
        guard let runSpan = span(runs), let riseSpan = span(heights) else { return .inconclusive }
        guard riseSpan >= minimumRise, runSpan >= minimumRun else { return .notStairs }

        let meanRun = runs.reduce(0, +) / Float(runs.count)
        let meanHeight = heights.reduce(0, +) / Float(heights.count)
        var covariance: Float = 0, runVariance: Float = 0, heightVariance: Float = 0
        for (run, height) in zip(runs, heights) {
            covariance += (run - meanRun) * (height - meanHeight)
            runVariance += (run - meanRun) * (run - meanRun)
            heightVariance += (height - meanHeight) * (height - meanHeight)
        }
        guard runVariance > 0, heightVariance > 0 else { return .notStairs }
        let correlation = covariance / (runVariance * heightVariance).squareRoot()
        let incline = atan(abs(covariance / runVariance)) * 180 / .pi
        return abs(correlation) >= minimumCorrelation && inclineRange.contains(incline) ? .stairs : .notStairs
    }

    private static func span(_ values: [Float]) -> Float? {
        guard let low = values.min(), let high = values.max() else { return nil }
        return high - low
    }
}
