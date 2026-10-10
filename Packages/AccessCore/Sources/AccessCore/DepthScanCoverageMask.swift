import Foundation

/// Sensor-native alpha pixels for a subtle green overlay. Display rotation and
/// camera cropping belong to the view, using the same frame's display transform.
public struct DepthScanCoverageMask: Sendable {
    public let width: Int
    public let height: Int
    public let alpha: [UInt8]

    public init(width: Int, height: Int, alpha: [UInt8]) {
        self.width = width; self.height = height; self.alpha = alpha
    }
}

extension DepthScanCoverageSnapshot {
    /// Highlights only compatible current measurements near saved measurements.
    /// Up to 8,000 spatial queries seed small, uniformly spaced patches; every
    /// painted pixel independently passes current confidence/neighbor support and
    /// the saved point's distance/orientation checks. Holes are never interpolated.
    /// New evidence fades in over 0.35 seconds. Disappearing evidence clears at once.
    // Keep this camera display work fast when scanning in a Debug build too.
    @_optimize(speed)
    public func mask(for frame: CaptureDepthFrame) -> DepthScanCoverageMask? {
        guard !Task.isCancelled, let geometry = CoverageFrameGeometry(frame) else { return nil }
        let width = geometry.image.width, height = geometry.image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard !isEmpty else { return .init(width: width, height: height, alpha: alpha) }
        let step = geometry.sampleStep
        let radius = step / 2
        var visited = 0
        for row in stride(from: 1, to: height - 1, by: step) {
            guard !Task.isCancelled else { return nil }
            for column in stride(from: 1, to: width - 1, by: step) {
                guard visited < DepthScanCoverage.maximumSampledPixels else {
                    return .init(width: width, height: height, alpha: alpha)
                }
                visited += 1
                guard let center = geometry.supportedSample(column: column, row: row),
                      let observed = matchingObservation(point: center.point, normal: center.normal, nearest: true) else { continue }
                let fade = min(1, max(0, (frame.timestampSeconds - observed.capturedAt) / 0.35))
                let value = UInt8((fade * 55).rounded())
                guard value > 0 else { continue }
                for y in max(1, row - radius)...min(height - 2, row + radius) {
                    for x in max(1, column - radius)...min(width - 2, column + radius) {
                        let measured: DepthScanCoverageSample
                        if x == column, y == row {
                            measured = center
                        } else {
                            guard let supported = geometry.supportedSample(column: x, row: y) else { continue }
                            measured = supported
                        }
                        guard coverageMatches(observed, point: measured.point, normal: measured.normal) else { continue }
                        let index = y * width + x
                        alpha[index] = max(alpha[index], value)
                    }
                }
            }
        }
        return .init(width: width, height: height, alpha: alpha)
    }
}
