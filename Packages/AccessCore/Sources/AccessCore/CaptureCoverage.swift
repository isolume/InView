import simd

/// Pose-space coverage math for bounded capture evidence (depth keyframes, OCR stills).
///
/// A capture can only keep a fixed number of expensive observations. Instead of dropping the
/// oldest (which loses the first rooms of a long walk), it drops the observation whose removal
/// least reduces coverage: the one with the closest neighbour in pose space, where distance
/// combines camera travel and change of view direction.
public enum CaptureCoverage {
    /// A camera position and its unit viewing direction in the shared ARKit frame.
    public struct Pose: Sendable, Equatable {
        public var position: SIMD3<Float>
        public var forward: SIMD3<Float>

        public init(position: SIMD3<Float>, forward: SIMD3<Float>) {
            self.position = position
            let length = simd_length(forward)
            self.forward = length > 0 && length.isFinite ? forward / length : SIMD3(0, 0, -1)
        }

        /// ARKit cameras look along their local `-z` axis.
        public init(mapFromCamera m: simd_float4x4) {
            self.init(
                position: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                forward: -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            )
        }

        /// A 16-entry column-major `map_from_camera`, as stored in capture frames.
        public init?(columnMajor m: [Float]) {
            guard m.count == 16, m.allSatisfy(\.isFinite) else { return nil }
            self.init(position: SIMD3(m[12], m[13], m[14]), forward: -SIMD3(m[8], m[9], m[10]))
        }
    }

    /// Angle between two viewing directions, in radians (0...π).
    public static func viewAngle(_ a: Pose, _ b: Pose) -> Float {
        acos(min(1, max(-1, simd_dot(a.forward, b.forward))))
    }

    /// Travel in metres plus view-direction change weighted by `metersPerRadian`.
    public static func distance(_ a: Pose, _ b: Pose, metersPerRadian: Float) -> Float {
        simd_distance(a.position, b.position) + metersPerRadian * viewAngle(a, b)
    }

    /// Smallest pose distance from `pose` to any of `others` (`.infinity` when there are none).
    public static func nearestDistance(from pose: Pose, to others: [Pose], metersPerRadian: Float) -> Float {
        others.reduce(Float.infinity) { min($0, distance(pose, $1, metersPerRadian: metersPerRadian)) }
    }

    /// The index whose removal least reduces coverage, or nil when there is nothing to remove.
    ///
    /// Every pose counts as a neighbour, but `protected` indices are only candidates when no
    /// unprotected pose remains. `retentionBonus` adds metres of "virtual distance" to make a
    /// candidate more expensive to remove (e.g. it also carries a colour image). Ties go to the
    /// denser neighbourhood (smaller second-nearest distance), then to the older index.
    public static func mostRedundantIndex(
        _ poses: [Pose], metersPerRadian: Float, protected: Set<Int> = [],
        retentionBonus: (Int) -> Float = { _ in 0 }
    ) -> Int? {
        guard poses.count > 1 else { return poses.isEmpty ? nil : 0 }
        var candidates = poses.indices.filter { !protected.contains($0) }
        if candidates.isEmpty { candidates = Array(poses.indices) }
        var best: (index: Int, score: Float, second: Float)?
        for i in candidates {
            var nearest = Float.infinity
            var second = Float.infinity
            for j in poses.indices where j != i {
                let d = distance(poses[i], poses[j], metersPerRadian: metersPerRadian)
                if d < nearest {
                    second = nearest
                    nearest = d
                } else if d < second {
                    second = d
                }
            }
            let score = nearest + retentionBonus(i)
            if let current = best, score > current.score || (score == current.score && second >= current.second) {
                continue
            }
            best = (i, score, second)
        }
        return best?.index
    }

    /// Rotation angle (radians, 0...π) between the orientations of two rigid transforms.
    public static func rotationAngle(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let ra = simd_float3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z),
                               SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                               SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_float3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z),
                               SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                               SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        // trace(Raᵀ Rb) = 1 + 2 cos θ.
        let relative = ra.transpose * rb
        let trace = relative.columns.0.x + relative.columns.1.y + relative.columns.2.z
        return acos(min(1, max(-1, (trace - 1) / 2)))
    }
}
