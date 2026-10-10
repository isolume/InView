import Foundation

/// Coarse geographic/building context for a scan observation (GPS, heading, barometer). ARKit's
/// shared local frame remains the only room-precision coordinate system; these are supporting
/// evidence for placing the building, estimating floors, and timing poses on the wall clock.
public struct CaptureEnvironmentSample: Codable, Equatable, Sendable {
    public var recordedAtUnixSeconds: Double
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracyM: Double?
    public var altitudeM: Double?
    public var verticalAccuracyM: Double?
    public var courseDegrees: Double?
    public var speedMps: Double?
    public var headingDegrees: Double?
    public var headingAccuracyDegrees: Double?
    public var relativeAltitudeM: Double?
    public var pressureKPa: Double?

    public init(recordedAtUnixSeconds: Double, latitude: Double? = nil, longitude: Double? = nil,
                horizontalAccuracyM: Double? = nil, altitudeM: Double? = nil, verticalAccuracyM: Double? = nil,
                courseDegrees: Double? = nil, speedMps: Double? = nil, headingDegrees: Double? = nil,
                headingAccuracyDegrees: Double? = nil, relativeAltitudeM: Double? = nil, pressureKPa: Double? = nil) {
        self.recordedAtUnixSeconds = recordedAtUnixSeconds
        self.latitude = latitude; self.longitude = longitude; self.horizontalAccuracyM = horizontalAccuracyM
        self.altitudeM = altitudeM; self.verticalAccuracyM = verticalAccuracyM; self.courseDegrees = courseDegrees
        self.speedMps = speedMps; self.headingDegrees = headingDegrees
        self.headingAccuracyDegrees = headingAccuracyDegrees; self.relativeAltitudeM = relativeAltitudeM
        self.pressureKPa = pressureKPa
    }

    enum CodingKeys: String, CodingKey {
        case recordedAtUnixSeconds = "recorded_at_unix_seconds"
        case latitude, longitude, altitudeM = "altitude_m", horizontalAccuracyM = "horizontal_accuracy_m"
        case verticalAccuracyM = "vertical_accuracy_m", courseDegrees = "course_degrees", speedMps = "speed_mps"
        case headingDegrees = "heading_degrees", headingAccuracyDegrees = "heading_accuracy_degrees"
        case relativeAltitudeM = "relative_altitude_m", pressureKPa = "pressure_kpa"
    }

    /// Every present value is finite (the backend rejects anything else).
    public var isFinite: Bool {
        let values: [Double?] = [recordedAtUnixSeconds, latitude, longitude, horizontalAccuracyM, altitudeM,
                                 verticalAccuracyM, courseDegrees, speedMps, headingDegrees, headingAccuracyDegrees,
                                 relativeAltitudeM, pressureKPa]
        return values.allSatisfy { $0?.isFinite ?? true }
    }
}

/// One pose of the dense movement track between streamed keyframes (shared ARKit frame).
public struct StreamPose: Codable, Equatable, Sendable {
    /// ARKit uptime seconds, the clock of `CaptureDepthFrame.timestampSeconds`.
    public var t: Double
    /// Column-major map_from_camera.
    public var m: [Float]
    /// `normal`, `limited:<reason>`, or `not_available`.
    public var tracking: String?
    /// `not_available`, `limited`, `extending`, or `mapped`.
    public var mapping: String?

    public init(t: Double, m: [Float], tracking: String? = nil, mapping: String? = nil) {
        self.t = t; self.m = m; self.tracking = tracking; self.mapping = mapping
    }

    public var isValid: Bool { t.isFinite && t >= 0 && m.count == 16 && m.allSatisfy(\.isFinite) }
}

/// Whole-capture files a continuous capture attaches to its stream before finishing.
public enum StreamAttachment {
    public static let allowedNames: Set<String> = ["roomplan.json", "semantics.json", "text-observations.json",
                                                   "camera-track.json"]
    public static let maximumBytes = 16 * 1024 * 1024
}
