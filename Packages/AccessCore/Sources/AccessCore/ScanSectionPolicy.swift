import Foundation
import simd

/// Keep each RoomPlan fit local while the shared AR session continues across sections.
public struct ScanSectionPolicy: Sendable {
    public let maximumSpan: Float
    public let maximumDuration: TimeInterval
    public let minimumDuration: TimeInterval
    private var started: TimeInterval?
    private var lower: SIMD2<Float>?
    private var upper: SIMD2<Float>?

    public init(maximumSpan: Float = 7, maximumDuration: TimeInterval = 120,
                minimumDuration: TimeInterval = 15) {
        self.maximumSpan = maximumSpan
        self.maximumDuration = maximumDuration
        self.minimumDuration = minimumDuration
    }

    public mutating func reset() { started = nil; lower = nil; upper = nil }

    /// Called only during normal, current tracking; never split repeatedly while processing.
    public mutating func shouldSave(position: SIMD2<Float>, timestamp: TimeInterval) -> Bool {
        guard position.x.isFinite, position.y.isFinite, timestamp.isFinite else { return false }
        if started == nil { started = timestamp }
        guard let started, timestamp >= started else { return false }
        lower = simd_min(lower ?? position, position)
        upper = simd_max(upper ?? position, position)
        let elapsed = timestamp - started
        guard elapsed >= minimumDuration else { return false }
        let span = (upper ?? position) - (lower ?? position)
        return max(span.x, span.y) >= maximumSpan || elapsed >= maximumDuration
    }
}
