import Foundation

/// Bounds both the sensor bytes and decoded arrays retained for optional depth keyframes.
/// A larger depth image retains fewer frames rather than growing with the length of a scan.
public struct DepthKeyframeBudget: Sendable {
    public var maximumFrames: Int
    public var maximumPixels: Int
    public var maximumNativeFrameBytes: Int
    public var maximumRetainedBytes: Int

    public init(maximumFrames: Int = 6, maximumPixels: Int = 512 * 512,
                maximumNativeFrameBytes: Int = 2 * 1024 * 1024,
                maximumRetainedBytes: Int = 8 * 1024 * 1024) {
        self.maximumFrames = maximumFrames
        self.maximumPixels = maximumPixels
        self.maximumNativeFrameBytes = maximumNativeFrameBytes
        self.maximumRetainedBytes = maximumRetainedBytes
    }

    /// Returns the retained byte cost only for a complete image that fits every limit.
    /// Include padded rows because the native archive preserves their original layout.
    public func frameCost(width: Int, height: Int, depthBytesPerRow: Int,
                          confidenceBytesPerRow: Int?) -> Int? {
        guard width > 0, height > 0, maximumFrames > 0,
              maximumPixels > 0, maximumNativeFrameBytes > 0, maximumRetainedBytes > 0,
              let pixels = Self.product(width, height), pixels <= maximumPixels,
              let minimumDepthStride = Self.product(width, MemoryLayout<Float>.stride),
              depthBytesPerRow >= minimumDepthStride,
              let depthBytes = Self.product(depthBytesPerRow, height) else { return nil }
        var nativeBytes = depthBytes
        var decodedBytesPerPixel = MemoryLayout<Float?>.stride
        if let confidenceStride = confidenceBytesPerRow {
            guard confidenceStride >= width,
                  let confidenceBytes = Self.product(confidenceStride, height),
                  let combinedBytes = Self.sum(nativeBytes, confidenceBytes) else { return nil }
            nativeBytes = combinedBytes
            decodedBytesPerPixel += MemoryLayout<Int>.stride
        }
        guard nativeBytes <= maximumNativeFrameBytes,
              let decodedBytes = Self.product(pixels, decodedBytesPerPixel),
              let totalBytes = Self.sum(nativeBytes, decodedBytes),
              totalBytes <= maximumRetainedBytes else { return nil }
        return totalBytes
    }

    /// The newest complete frames that fit. Frame pairs are evicted together, never truncated.
    public func retainedSuffixCount(costs: [Int]) -> Int {
        guard maximumFrames > 0, maximumRetainedBytes > 0 else { return 0 }
        var retained = 0
        var bytes = 0
        for cost in costs.reversed() {
            guard retained < maximumFrames, cost > 0,
                  let nextBytes = Self.sum(bytes, cost), nextBytes <= maximumRetainedBytes else { break }
            bytes = nextBytes
            retained += 1
        }
        return retained
    }

    private static func product(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : result
    }

    private static func sum(_ lhs: Int, _ rhs: Int) -> Int? {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : result
    }
}
