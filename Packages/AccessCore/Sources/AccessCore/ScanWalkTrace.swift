import Foundation
import simd

/// Bounded camera observations from one scan. A walk is evidence to review, never measured floor.
public struct ScanWalkTrace: Codable, Sendable, Equatable {
    public static let maximumSamples = 4_096

    public struct Sample: Codable, Sendable, Equatable {
        public let cameraPosition: SIMD3<Float>
        public let timestampSeconds: TimeInterval
        public let startsSegment: Bool

        public init(cameraPosition: SIMD3<Float>, timestampSeconds: TimeInterval, startsSegment: Bool) {
            self.cameraPosition = cameraPosition
            self.timestampSeconds = timestampSeconds
            self.startsSegment = startsSegment
        }
    }

    public let samples: [Sample]
    /// Recording stopped at its sample budget; no claim is made about the unrecorded remainder.
    public let isTruncated: Bool

    public init(samples: [Sample] = [], isTruncated: Bool = false) throws {
        guard samples.count <= Self.maximumSamples,
              samples.first?.startsSegment != false else { throw ValidationError.invalidTrace }
        var previous: TimeInterval?
        for sample in samples {
            guard Self.valid(sample.cameraPosition), sample.timestampSeconds.isFinite,
                  sample.timestampSeconds >= 0,
                  previous.map({ sample.timestampSeconds > $0 }) ?? true else {
                throw ValidationError.invalidTrace
            }
            previous = sample.timestampSeconds
        }
        self.samples = samples
        self.isTruncated = isTruncated
    }

    /// Separate runs for drawing. Never join the end of one run to the start of another.
    public var segments: [[Sample]] {
        var result: [[Sample]] = []
        for sample in samples {
            if sample.startsSegment || result.isEmpty { result.append([]) }
            result[result.count - 1].append(sample)
        }
        return result
    }

    /// Horizontal recorded distance. Tracking gaps and camera-height changes add no distance.
    public var distanceMeters: Float {
        zip(samples, samples.dropFirst()).reduce(0) { sum, pair in
            pair.1.startsSegment ? sum : sum + simd_distance(Self.flat(pair.0.cameraPosition), Self.flat(pair.1.cameraPosition))
        }
    }

    /// Time represented by connected observations, excluding suspended/untracked intervals.
    public var durationSeconds: TimeInterval {
        zip(samples, samples.dropFirst()).reduce(0) { sum, pair in
            pair.1.startsSegment ? sum : sum + pair.1.timestampSeconds - pair.0.timestampSeconds
        }
    }

    public enum ValidationError: Error { case invalidTrace }
    private enum CodingKeys: String, CodingKey { case samples, isTruncated }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var values = try container.nestedUnkeyedContainer(forKey: .samples)
        var samples: [Sample] = []
        while !values.isAtEnd {
            guard samples.count < Self.maximumSamples else { throw ValidationError.invalidTrace }
            samples.append(try values.decode(Sample.self))
        }
        try self.init(samples: samples, isTruncated: container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false)
    }

    fileprivate static func valid(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
            && abs(point.x) <= 100_000 && abs(point.y) <= 100_000 && abs(point.z) <= 100_000
    }

    fileprivate static func flat(_ point: SIMD3<Float>) -> SIMD2<Float> { [point.x, point.z] }
}

/// Feed only frame timestamps in one monotonic clock. Explicit freshness and tracking gates prevent
/// an old pose, relocalization jump, or resumed capture from inventing a connecting walk.
public struct ScanWalkTraceRecorder: Sendable {
    public struct Configuration: Sendable {
        public let spacingMeters: Float
        public let maximumGapSeconds: TimeInterval
        public let maximumJumpMeters: Float
        public let maximumSpeedMetersPerSecond: Float
        public let maximumSamples: Int

        public init(spacingMeters: Float = 0.25, maximumGapSeconds: TimeInterval = 1,
                    maximumJumpMeters: Float = 2, maximumSpeedMetersPerSecond: Float = 3,
                    maximumSamples: Int = ScanWalkTrace.maximumSamples) {
            self.spacingMeters = spacingMeters.isFinite ? min(0.5, max(0.05, spacingMeters)) : 0.25
            self.maximumGapSeconds = maximumGapSeconds.isFinite ? min(2, max(0.1, maximumGapSeconds)) : 1
            self.maximumJumpMeters = maximumJumpMeters.isFinite ? min(3, max(0.25, maximumJumpMeters)) : 2
            self.maximumSpeedMetersPerSecond = maximumSpeedMetersPerSecond.isFinite
                ? min(5, max(0.5, maximumSpeedMetersPerSecond)) : 3
            self.maximumSamples = min(ScanWalkTrace.maximumSamples, max(2, maximumSamples))
        }
    }

    public let configuration: Configuration
    private var saved: [ScanWalkTrace.Sample] = []
    private var previous: ScanWalkTrace.Sample?
    private var lastTimestamp: TimeInterval?
    private var truncated = false

    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    /// Includes the current run's most recent endpoint, even before it reaches the spacing threshold.
    public var trace: ScanWalkTrace {
        var values = saved
        var limited = truncated
        if let previous, previous.timestampSeconds != values.last?.timestampSeconds {
            if values.count < configuration.maximumSamples { values.append(previous) } else { limited = true }
        }
        // All writes below enforce the same invariants as the archive initializer.
        return try! ScanWalkTrace(samples: values, isTruncated: limited)
    }

    /// Returns whether this frame was accepted as a trusted observation, not whether a point was kept.
    @discardableResult
    public mutating func record(cameraPosition: SIMD3<Float>, timestampSeconds: TimeInterval,
                                trackingIsNormal: Bool, frameIsFresh: Bool) -> Bool {
        guard trackingIsNormal, frameIsFresh, ScanWalkTrace.valid(cameraPosition),
              timestampSeconds.isFinite, timestampSeconds >= 0,
              lastTimestamp.map({ timestampSeconds > $0 }) ?? true else {
            suspend()
            return false
        }
        guard !truncated else { return false }
        if let previous {
            let elapsed = timestampSeconds - previous.timestampSeconds
            let movement = simd_distance(cameraPosition, previous.cameraPosition)
            if elapsed > configuration.maximumGapSeconds || movement > configuration.maximumJumpMeters
                || movement > max(0.3, Float(elapsed) * configuration.maximumSpeedMetersPerSecond) {
                suspend()
            }
        }
        guard !truncated else { return false }
        let sample = ScanWalkTrace.Sample(cameraPosition: cameraPosition, timestampSeconds: timestampSeconds,
                                         startsSegment: previous == nil)
        if previous == nil {
            append(sample)
        } else if let previous, let anchor = saved.last {
            // Preserve a meaningful short corner before ordinary distance decimation can cut it off.
            let inbound = ScanWalkTrace.flat(previous.cameraPosition - anchor.cameraPosition)
            let outbound = ScanWalkTrace.flat(cameraPosition - previous.cameraPosition)
            if simd_length(inbound) >= 0.04, simd_length(outbound) >= 0.02,
               simd_dot(simd_normalize(inbound), simd_normalize(outbound)) < 0.866 {
                append(previous)
            }
            if let last = saved.last,
               simd_distance(ScanWalkTrace.flat(last.cameraPosition), ScanWalkTrace.flat(cameraPosition)) >= configuration.spacingMeters {
                append(sample)
            }
        }
        previous = truncated ? nil : sample
        lastTimestamp = timestampSeconds
        return !truncated
    }

    /// Flushes the measured endpoint and forces the next accepted observation to start a new run.
    public mutating func suspend() {
        if let previous { append(previous) }
        previous = nil
    }

    private mutating func append(_ sample: ScanWalkTrace.Sample) {
        guard saved.last?.timestampSeconds != sample.timestampSeconds else { return }
        guard saved.count < configuration.maximumSamples else { truncated = true; return }
        saved.append(sample)
    }
}

/// Compares a floor-projected walk with measured footprints. It reports omissions for scan review;
/// it does not widen the walk into floor, infer room boundaries, or determine accessibility.
public enum ScanWalkFloorCoverage {
    public static let boundaryToleranceMeters: Float = 0.15
    public static let floorHeightToleranceMeters: Float = 0.2
    public static let intervalMeters: Float = 0.1
    public static let maximumEvaluatedPoints = 32_768
    public static let maximumFootprints = 4_096
    public static let maximumFloorVertices = 4_096
    public static let maximumPolygonVertices = 128
    public static let maximumWork = 2_000_000

    public struct Assessment: Sendable, Equatable {
        /// Runs of sampled missing coverage, at map.floorY. Isolated misses contain one point.
        public fileprivate(set) var missingSegments: [[SIMD3<Float>]] = []
        public fileprivate(set) var evaluatedPointCount = 0
        public fileprivate(set) var measuredFloorCount = 0
        /// The trace or assessment reached a budget, or the map floor height was invalid.
        public fileprivate(set) var isLimited = false
        public var hasMissingCoverage: Bool { !missingSegments.isEmpty }
        public var message: String? { hasMissingCoverage ? "Floor coverage missing along recorded walk" : nil }
    }

    private struct Floor {
        let polygon: [SIMD2<Float>]
        let lower: SIMD2<Float>
        let upper: SIMD2<Float>
    }

    public static func assess(trace: ScanWalkTrace, map: VenueMap) -> Assessment {
        var result = Assessment()
        result.isLimited = trace.isTruncated
        guard map.floorY.isFinite, abs(map.floorY) <= 100_000,
              map.footprints.count <= maximumFootprints else { result.isLimited = true; return result }
        var floors: [Floor] = []
        var vertexCount = 0
        var work = 0
        for footprint in map.footprints where footprint.kind == .floor {
            guard let bottom = footprint.bottom, bottom.isFinite,
                  abs(bottom - map.floorY) <= floorHeightToleranceMeters,
                  footprint.center.x.isFinite, footprint.center.y.isFinite,
                  footprint.size.x.isFinite, footprint.size.y.isFinite,
                  footprint.size.x > 0, footprint.size.y > 0, footprint.yaw.isFinite else { continue }
            if let polygon = footprint.polygon {
                guard polygon.count <= maximumPolygonVertices else { result.isLimited = true; return result }
                if polygon.count < 3 { continue }
            }
            let polygon = footprint.corners
            guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 100_000 && abs($0.y) <= 100_000 }) else { continue }
            let valid = simple(polygon, work: &work)
            guard work < maximumWork else { result.isLimited = true; return result }
            guard valid else { continue }
            vertexCount += polygon.count
            // An omitted valid floor could explain any apparent gap. Stop rather than label it missing.
            guard vertexCount <= maximumFloorVertices, work < maximumWork else { result.isLimited = true; return result }
            var lower = polygon[0], upper = polygon[0]
            for point in polygon { lower = simd_min(lower, point); upper = simd_max(upper, point) }
            floors.append(Floor(polygon: polygon, lower: lower, upper: upper))
        }
        result.measuredFloorCount = floors.count
        var missing: [SIMD3<Float>] = []
        func flush() {
            if !missing.isEmpty { result.missingSegments.append(missing); missing.removeAll(keepingCapacity: true) }
        }
        func evaluate(_ position: SIMD3<Float>) -> Bool {
            guard result.evaluatedPointCount < maximumEvaluatedPoints else { result.isLimited = true; return false }
            let point = ScanWalkTrace.flat(position)
            guard let covered = contains(point, floors: floors, work: &work) else { result.isLimited = true; return false }
            result.evaluatedPointCount += 1
            if covered { flush() } else { missing.append([point.x, map.floorY, point.y]) }
            return true
        }
        var previous: ScanWalkTrace.Sample?
        walk: for sample in trace.samples {
            if sample.startsSegment || previous == nil {
                flush()
                if !evaluate(sample.cameraPosition) { break }
            } else if let previous {
                let distance = simd_distance(ScanWalkTrace.flat(previous.cameraPosition), ScanWalkTrace.flat(sample.cameraPosition))
                let required = max(1, Int(ceil(Double(distance) / Double(intervalMeters))))
                // Visit a bounded prefix at the declared spacing; never coarsen across an unexamined gap.
                let count = min(required, maximumEvaluatedPoints - result.evaluatedPointCount)
                if count == 0 { result.isLimited = true; break }
                for step in 1...count {
                    let t = Float(step) / Float(required)
                    if !evaluate(previous.cameraPosition + (sample.cameraPosition - previous.cameraPosition) * t) { break walk }
                }
                if count < required { result.isLimited = true; break }
            }
            previous = sample
        }
        flush()
        return result
    }

    private static func contains(_ point: SIMD2<Float>, floors: [Floor], work: inout Int) -> Bool? {
        let tolerance = boundaryToleranceMeters
        for floor in floors {
            work += 1
            if work >= maximumWork { return nil }
            if point.x < floor.lower.x - tolerance || point.x > floor.upper.x + tolerance
                || point.y < floor.lower.y - tolerance || point.y > floor.upper.y + tolerance { continue }
            var inside = false
            for index in floor.polygon.indices {
                work += 1
                if work >= maximumWork { return nil }
                let a = floor.polygon[index], b = floor.polygon[(index + 1) % floor.polygon.count]
                let delta = b - a
                let t = simd_clamp(simd_dot(point - a, delta) / simd_length_squared(delta), 0, 1)
                if simd_distance(point, a + delta * t) <= tolerance { return true }
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            if inside { return true }
        }
        return false
    }

    /// Reject degeneracy, self crossings and self touching; no bounding-box replacement for a bad ring.
    private static func simple(_ polygon: [SIMD2<Float>], work: inout Int) -> Bool {
        guard polygon.count >= 3 else { return false }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Double {
            let x1 = Double(b.x) - Double(a.x), y1 = Double(b.y) - Double(a.y)
            let x2 = Double(c.x) - Double(a.x), y2 = Double(c.y) - Double(a.y)
            return x1 * y2 - y1 * x2
        }
        func onSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
            abs(cross(a, b, p)) <= 1e-8 && p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x)
                && p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y)
        }
        var area: Double = 0
        for first in polygon.indices {
            let firstEnd = (first + 1) % polygon.count
            let a = polygon[first], b = polygon[firstEnd]
            guard simd_distance(a, b) > 1e-5 else { return false }
            area += cross(polygon[0], a, b)
            for second in (first + 1)..<polygon.count {
                work += 1
                guard work < maximumWork else { return false }
                let secondEnd = (second + 1) % polygon.count
                if firstEnd == second || secondEnd == first { continue }
                let c = polygon[second], d = polygon[secondEnd]
                if (cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0)
                    || onSegment(c, a, b) || onSegment(d, a, b) || onSegment(a, c, d) || onSegment(b, c, d) { return false }
            }
        }
        return abs(area) > 1e-6
    }
}
