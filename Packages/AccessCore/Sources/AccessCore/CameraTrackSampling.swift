import Foundation

/// Sampling schedule for the dense camera track: one timer at the base rate, with the accepted
/// spacing widening each time the bounded track is decimated. Pure so the policy is testable
/// without ARKit; the recorder in the app drives it from `ARSession.currentFrame`.
public struct CameraTrackSampling: Equatable, Sendable {
    /// Upper bound: ARKit publishes at most 60 frames per second.
    public static let maximumRateHz = 60.0

    /// Fixed timer period, derived from the requested rate.
    public let timerInterval: TimeInterval
    /// Minimum spacing between accepted samples; doubles on every decimation.
    public private(set) var interval: TimeInterval

    /// Returns nil for a non-finite, non-positive, or faster-than-ARKit rate.
    public init?(rateHz: Double) {
        guard rateHz.isFinite, rateHz > 0, rateHz <= Self.maximumRateHz else { return nil }
        timerInterval = 1 / rateHz
        interval = timerInterval
    }

    /// The timer can fire faster than ARKit publishes and decimation widens the spacing, so a
    /// sample is kept only once it is at least ~¾ of the current interval after the previous one.
    public func accepts(timestamp: TimeInterval, after previous: TimeInterval?) -> Bool {
        guard let previous else { return true }
        return timestamp - previous >= interval * 0.75
    }

    public mutating func decimate() {
        interval *= 2
    }
}
