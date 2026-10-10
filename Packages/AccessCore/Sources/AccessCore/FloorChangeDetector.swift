import Foundation

/// Finds a settled landing from a continuous stream of relative elevation samples.
/// The caller decides whether the suggested floor matches the building's floor labels.
public struct FloorChangeDetector: Sendable {
    public struct Proposal: Sendable, Equatable {
        public let floorDelta: Int
        public let elevationDeltaMeters: Double
        public let landingElevationMeters: Double
        public let timestamp: TimeInterval
    }

    public let typicalStoreyHeightMeters: Double
    public let minimumChangeMeters: Double
    public let movementThresholdMeters: Double
    public let movementDuration: TimeInterval
    public let landingDuration: TimeInterval
    public let baselineDuration: TimeInterval
    public let stableToleranceMeters: Double
    public let maximumSampleGap: TimeInterval

    /// True during a substantial elevation change and while a proposal awaits rebasing.
    public private(set) var isChangingElevation = false

    private struct Sample: Sendable {
        let elevation: Double
        let timestamp: TimeInterval
    }

    private var samples: [Sample] = []
    private var baseline: Double?
    private var latest: Sample?
    private var movementStarted: TimeInterval?
    private var movementDirection = 0
    private var hasProposed = false

    public init(typicalStoreyHeightMeters: Double = 3.2,
                minimumChangeMeters: Double = 2.2,
                movementThresholdMeters: Double = 1.6,
                movementDuration: TimeInterval = 1.5,
                landingDuration: TimeInterval = 2.5,
                baselineDuration: TimeInterval = 2,
                stableToleranceMeters: Double = 0.35,
                maximumSampleGap: TimeInterval = 5) {
        let positiveValues = [typicalStoreyHeightMeters, minimumChangeMeters,
                              movementThresholdMeters, movementDuration, landingDuration,
                              baselineDuration, stableToleranceMeters, maximumSampleGap]
        precondition(positiveValues.allSatisfy { $0.isFinite && $0 > 0 })
        precondition(stableToleranceMeters < movementThresholdMeters)
        precondition(movementThresholdMeters < minimumChangeMeters)
        self.typicalStoreyHeightMeters = typicalStoreyHeightMeters
        self.minimumChangeMeters = minimumChangeMeters
        self.movementThresholdMeters = movementThresholdMeters
        self.movementDuration = movementDuration
        self.landingDuration = landingDuration
        self.baselineDuration = baselineDuration
        self.stableToleranceMeters = stableToleranceMeters
        self.maximumSampleGap = maximumSampleGap
    }

    /// Non-finite, duplicate and out-of-order samples have no effect. After a long
    /// interruption a fresh stable baseline is needed, so a sensor restart cannot look
    /// like travel between floors. Use one monotonic clock and one elevation source.
    public mutating func update(elevationMeters: Double, timestamp: TimeInterval) -> Proposal? {
        guard elevationMeters.isFinite, timestamp.isFinite else { return nil }
        if let latest {
            guard timestamp > latest.timestamp else { return nil }
            if timestamp - latest.timestamp > maximumSampleGap { reset() }
        }

        let sample = Sample(elevation: elevationMeters, timestamp: timestamp)
        latest = sample
        samples.append(sample)
        trimHistory(at: timestamp)

        guard let baseline else {
            if let elevation = stableElevation(over: baselineDuration, at: timestamp) {
                self.baseline = elevation
                samples = [sample]
            }
            return nil
        }
        guard !hasProposed else { return nil }

        let delta = elevationMeters - baseline
        guard delta.isFinite else { return nil }
        guard abs(delta) >= movementThresholdMeters else {
            clearMovement()
            return nil
        }

        let direction = delta > 0 ? 1 : -1
        if direction != movementDirection {
            clearMovement()
            movementDirection = direction
            movementStarted = timestamp
        }
        if let movementStarted, timestamp - movementStarted >= movementDuration {
            isChangingElevation = true
        }

        guard isChangingElevation,
              let landing = stableElevation(over: landingDuration, at: timestamp) else {
            return nil
        }
        let landingDelta = landing - baseline
        guard landingDelta.isFinite, abs(landingDelta) >= minimumChangeMeters,
              (landingDelta > 0 ? 1 : -1) == direction else { return nil }

        let estimatedFloors = max(1, (abs(landingDelta) / typicalStoreyHeightMeters).rounded())
        guard estimatedFloors.isFinite, estimatedFloors < Double(Int.max) else { return nil }
        hasProposed = true
        return Proposal(floorDelta: direction * Int(estimatedFloors),
                        elevationDeltaMeters: landingDelta,
                        landingElevationMeters: landing,
                        timestamp: timestamp)
    }

    /// Clear when scanning stops or the sensor changes its relative elevation origin.
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        baseline = nil
        latest = nil
        hasProposed = false
        clearMovement()
    }

    /// Anchor to the latest valid sample after accepting or dismissing a suggestion,
    /// or after manually choosing the current floor. This suppresses repeated prompts
    /// for the same landing while still detecting the next journey.
    public mutating func rebase() {
        guard let latest else { reset(); return }
        baseline = latest.elevation
        samples = [latest]
        hasProposed = false
        clearMovement()
    }

    private mutating func clearMovement() {
        movementStarted = nil
        movementDirection = 0
        isChangingElevation = false
    }

    private mutating func trimHistory(at timestamp: TimeInterval) {
        let cutoff = timestamp - max(baselineDuration, landingDuration)
        // Keep the sample immediately before the window to prove its full duration.
        if let lastOldIndex = samples.lastIndex(where: { $0.timestamp <= cutoff }),
           lastOldIndex > 0 {
            samples.removeFirst(lastOldIndex)
        }
    }

    private func stableElevation(over duration: TimeInterval, at timestamp: TimeInterval) -> Double? {
        let cutoff = timestamp - duration
        guard let firstIndex = samples.lastIndex(where: { $0.timestamp <= cutoff }) else { return nil }
        let window = samples[firstIndex...]
        guard window.count >= 3,
              let minimum = window.map(\.elevation).min(),
              let maximum = window.map(\.elevation).max(),
              maximum - minimum <= stableToleranceMeters else { return nil }
        let sorted = window.map(\.elevation).sorted()
        return sorted[sorted.count / 2]
    }
}
