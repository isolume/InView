import Foundation

/// Sensor-native saved-surface evidence. Display rotation and
/// camera cropping belong to the view, using the same frame's display transform.
public struct DepthScanCoverageMask: Sendable {
    public let width: Int
    public let height: Int
    public let alpha: [UInt8]

    public init(width: Int, height: Int, alpha: [UInt8]) {
        self.width = width; self.height = height; self.alpha = alpha
    }

    /// A short inward feather softens the measured boundary without filling holes
    /// or expanding coverage. Distances saturate after three native-depth pixels.
    @_optimize(speed)
    public func feathered() -> DepthScanCoverageMask {
        guard width >= 3, height >= 3, width <= 512, height <= 512,
              alpha.count == width * height else { return self }
        var distance = alpha.map { $0 == 0 ? UInt8(0) : UInt8(9) }
        for row in 1..<height {
            if Task.isCancelled { return self }
            for column in 1..<width {
                let i = row * width + column
                distance[i] = min(distance[i], distance[i - 1] + 3,
                                  distance[i - width] + 3, distance[i - width - 1] + 4)
                if column + 1 < width { distance[i] = min(distance[i], distance[i - width + 1] + 4) }
            }
        }
        for row in stride(from: height - 2, through: 0, by: -1) {
            if Task.isCancelled { return self }
            for column in stride(from: width - 2, through: 0, by: -1) {
                let i = row * width + column
                distance[i] = min(distance[i], distance[i + 1] + 3,
                                  distance[i + width] + 3, distance[i + width + 1] + 4)
                if column > 0 { distance[i] = min(distance[i], distance[i + width - 1] + 4) }
            }
        }
        let softened = alpha.indices.map { i -> UInt8 in
            let t = min(1, Float(distance[i]) / 9)
            return UInt8((Float(alpha[i]) * t * t * (3 - 2 * t)).rounded())
        }
        return .init(width: width, height: height, alpha: softened)
    }
}

extension DepthScanCoverageSnapshot {
    /// Highlights only compatible current measurements near saved measurements.
    /// Every painted pixel passes current confidence/neighbor support and the saved
    /// point's distance/orientation checks. Compatible neighboring observations are
    /// reused before a spatial query, avoiding a grid of seeded rectangular patches.
    /// New evidence fades in over 0.35 seconds. Disappearing evidence clears at once.
    // Keep this camera display work fast when scanning in a Debug build too.
    @_optimize(speed)
    public func mask(for frame: CaptureDepthFrame) -> DepthScanCoverageMask? {
        guard !Task.isCancelled, let geometry = CoverageFrameGeometry(frame) else { return nil }
        let width = geometry.image.width, height = geometry.image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard !isEmpty else { return .init(width: width, height: height, alpha: alpha) }
        var previousRow = [CoverageObservation?](repeating: nil, count: width)
        for row in 1..<height - 1 {
            guard !Task.isCancelled else { return nil }
            var previous: CoverageObservation?
            for column in 1..<width - 1 {
                let above = previousRow[column]
                previousRow[column] = nil
                guard let measured = geometry.supportedSample(column: column, row: row) else {
                    previous = nil
                    continue
                }
                let observed: CoverageObservation?
                if let previous, coverageMatches(previous, point: measured.point, normal: measured.normal) {
                    observed = previous
                } else if let above, coverageMatches(above, point: measured.point, normal: measured.normal) {
                    observed = above
                } else {
                    observed = matchingObservation(point: measured.point, normal: measured.normal, nearest: true)
                }
                previous = observed
                previousRow[column] = observed
                guard let observed else { continue }
                let fade = min(1, max(0, (frame.timestampSeconds - observed.capturedAt) / 0.35))
                alpha[row * width + column] = UInt8((fade * 55).rounded())
            }
        }
        return .init(width: width, height: height, alpha: alpha)
    }
}
