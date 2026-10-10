import AccessCore
import ARKit
import Foundation
import simd

/// A dense camera pose track (`camera-track.json`) in the shared ARKit frame.
///
/// Samples are stored compactly (one timestamp, one matrix, two status bytes) while scanning;
/// the JSON schema is produced only when the snapshot is encoded, off the main thread:
///
///     {"schema_version":1,"clock":"arkit_uptime_seconds","unix_offset_seconds":<wall − arkit>,
///      "poses":[{"t":..,"m":[16 column-major],"tracking":"normal|limited:<reason>|not_available",
///                "mapping":"not_available|limited|extending|mapped"}]}
///
/// `t + unix_offset_seconds` is the iPhone wall clock for a pose, which also aligns ARKit times with
/// the wall-clock `recorded_at_unix_seconds` of the coarse environment samples.
struct CameraTrack: Codable, Sendable {
    enum Tracking: UInt8, Sendable, CaseIterable {
        case normal, initializing, excessiveMotion, insufficientFeatures, relocalizing, limitedOther, notAvailable

        init(_ state: ARCamera.TrackingState) {
            switch state {
            case .normal: self = .normal
            case .notAvailable: self = .notAvailable
            case .limited(let reason):
                switch reason {
                case .initializing: self = .initializing
                case .excessiveMotion: self = .excessiveMotion
                case .insufficientFeatures: self = .insufficientFeatures
                case .relocalizing: self = .relocalizing
                @unknown default: self = .limitedOther
                }
            }
        }

        var label: String {
            switch self {
            case .normal: "normal"
            case .initializing: "limited:initializing"
            case .excessiveMotion: "limited:excessive_motion"
            case .insufficientFeatures: "limited:insufficient_features"
            case .relocalizing: "limited:relocalizing"
            case .limitedOther: "limited:other"
            case .notAvailable: "not_available"
            }
        }
    }

    enum Mapping: UInt8, Sendable, CaseIterable {
        case notAvailable, limited, extending, mapped

        init(_ status: ARFrame.WorldMappingStatus) {
            switch status {
            case .notAvailable: self = .notAvailable
            case .limited: self = .limited
            case .extending: self = .extending
            case .mapped: self = .mapped
            @unknown default: self = .notAvailable
            }
        }

        var label: String {
            switch self {
            case .notAvailable: "not_available"
            case .limited: "limited"
            case .extending: "extending"
            case .mapped: "mapped"
            }
        }
    }

    struct Sample: Sendable {
        var timestamp: TimeInterval
        var mapFromCamera: simd_float4x4
        var tracking: Tracking
        var mapping: Mapping
    }

    var unixOffsetSeconds: Double
    var samples: [Sample]
    /// Nominal spacing after any decimation, recorded so consumers know the effective rate.
    var sampleIntervalSeconds: Double

    init(unixOffsetSeconds: Double, samples: [Sample], sampleIntervalSeconds: Double) {
        self.unixOffsetSeconds = unixOffsetSeconds
        self.samples = samples
        self.sampleIntervalSeconds = sampleIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", clock, unixOffsetSeconds = "unix_offset_seconds"
        case sampleIntervalSeconds = "sample_interval_seconds", poses
    }

    private enum PoseKeys: String, CodingKey { case t, m, tracking, mapping }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode("arkit_uptime_seconds", forKey: .clock)
        try container.encode(unixOffsetSeconds, forKey: .unixOffsetSeconds)
        try container.encode(sampleIntervalSeconds, forKey: .sampleIntervalSeconds)
        var poses = container.nestedUnkeyedContainer(forKey: .poses)
        for sample in samples {
            var pose = poses.nestedContainer(keyedBy: PoseKeys.self)
            try pose.encode(sample.timestamp, forKey: .t)
            try pose.encode(ScanExporter.matrix(sample.mapFromCamera), forKey: .m)
            try pose.encode(sample.tracking.label, forKey: .tracking)
            try pose.encode(sample.mapping.label, forKey: .mapping)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported camera track version.")
        }
        unixOffsetSeconds = try container.decode(Double.self, forKey: .unixOffsetSeconds)
        sampleIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .sampleIntervalSeconds) ?? 0.1
        var poses = try container.nestedUnkeyedContainer(forKey: .poses)
        var samples: [Sample] = []
        while !poses.isAtEnd {
            let pose = try poses.nestedContainer(keyedBy: PoseKeys.self)
            let m = try pose.decode([Float].self, forKey: .m)
            guard m.count == 16 else {
                throw DecodingError.dataCorruptedError(forKey: .m, in: pose, debugDescription: "A pose needs 16 matrix entries.")
            }
            let tracking = try pose.decode(String.self, forKey: .tracking)
            let mapping = try pose.decode(String.self, forKey: .mapping)
            samples.append(Sample(
                timestamp: try pose.decode(Double.self, forKey: .t),
                mapFromCamera: simd_float4x4(columns: (
                    SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                    SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])
                )),
                tracking: Tracking.allCases.first { $0.label == tracking } ?? .limitedOther,
                mapping: Mapping.allCases.first { $0.label == mapping } ?? .notAvailable
            ))
        }
        self.samples = samples
    }
}

/// Records camera poses at ~10 Hz from the shared RoomPlan session without becoming its delegate.
///
/// A main-run-loop timer reads `session.currentFrame`, copies four scalars and a matrix, and drops the
/// frame immediately, so ARKit's buffer pool is never held. Storage is preallocated and bounded: when
/// the track reaches `capacity`, every other sample is dropped and the sampling interval doubles,
/// keeping evidence for the whole walk instead of only its most recent minutes.
@MainActor
final class CameraTrackRecorder {
    /// 18,000 poses ≈ 30 min at 10 Hz, ≈ 4 MB of JSON (≈ 230 bytes per pose).
    let capacity: Int
    private(set) var interval: TimeInterval
    private weak var session: ARSession?
    private var timer: Timer?
    private var samples: [CameraTrack.Sample] = []
    private var unixOffset: Double?
    private(set) var decimations = 0

    init(rateHz: Double = 10, capacity: Int = 18_000) {
        interval = 1 / rateHz
        self.capacity = max(2, capacity)
        samples.reserveCapacity(self.capacity)
    }

    var count: Int { samples.count }

    func start(session: ARSession) {
        self.session = session
        if unixOffset == nil {
            // ARFrame.timestamp uses the same clock as systemUptime.
            unixOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        sample()
        timer?.invalidate()
        timer = nil
    }

    var track: CameraTrack? {
        guard let unixOffset, !samples.isEmpty else { return nil }
        return CameraTrack(unixOffsetSeconds: unixOffset, samples: samples, sampleIntervalSeconds: interval)
    }

    /// True when the last `window` seconds of normally tracked poses show the camera nearly still:
    /// below `maxAngularSpeed` (rad/s) and `maxLinearSpeed` (m/s). Used to pick blur-free stills.
    func isSteady(at timestamp: TimeInterval, window: TimeInterval = 0.3,
                  maxAngularSpeed: Float = 0.3, maxLinearSpeed: Float = 0.6) -> Bool {
        guard let last = samples.last, last.tracking == .normal, timestamp - last.timestamp < 0.25 else { return false }
        // Walk back to the first sample at least `window` older than the latest one.
        var index = samples.count - 1
        while index > 0, last.timestamp - samples[index].timestamp < window {
            index -= 1
            if samples[index].tracking != .normal { return false }
        }
        let earlier = samples[index]
        let elapsed = Float(last.timestamp - earlier.timestamp)
        // After decimation the spacing can exceed the window; a long gap says nothing about blur.
        guard elapsed >= Float(window) * 0.5, elapsed <= Float(window) * 3 else { return false }
        let angular = CaptureCoverage.rotationAngle(earlier.mapFromCamera, last.mapFromCamera) / elapsed
        let a = earlier.mapFromCamera.columns.3, b = last.mapFromCamera.columns.3
        let linear = simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z)) / elapsed
        return angular <= maxAngularSpeed && linear <= maxLinearSpeed
    }

    private func sample() {
        guard let frame = session?.currentFrame else { return }
        let timestamp = frame.timestamp
        // The timer can fire faster than ARKit publishes, and decimation widens the spacing.
        if let last = samples.last?.timestamp, timestamp - last < interval * 0.75 { return }
        if samples.count >= capacity { decimate() }
        samples.append(CameraTrack.Sample(
            timestamp: timestamp, mapFromCamera: frame.camera.transform,
            tracking: .init(frame.camera.trackingState), mapping: .init(frame.worldMappingStatus)
        ))
    }

    private func decimate() {
        var kept = 0
        for index in stride(from: 0, to: samples.count, by: 2) {
            samples[kept] = samples[index]
            kept += 1
        }
        samples.removeLast(samples.count - kept)
        interval *= 2
        decimations += 1
    }
}
