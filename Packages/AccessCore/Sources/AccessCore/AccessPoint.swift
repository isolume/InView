import Foundation
import simd

/// A place a wheelchair user can be guided to.
public struct AccessPoint: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case elevator
        case ramp
        case destination

        public var title: String {
            switch self {
            case .elevator: "Elevator"
            case .ramp: "Ramp"
            case .destination: "Destination"
            }
        }
    }

    /// How the point got onto the map.
    public enum Source: String, Codable, Sendable {
        case detected
        case manual
    }

    /// Steepest ramp the ADA allows: a 1:12 rise over run.
    public static let maximumRampSlope: Float = atan(1 / 12) * 180 / .pi

    public var id: UUID
    public var kind: Kind
    /// Short human name, e.g. "Lobby elevator". The crew uses it when reporting problems.
    public var name: String
    /// Position in the map's coordinates (the scan session's world space), in meters.
    /// x and z span the floor; y is up.
    public var position: SIMD3<Float>
    public var source: Source
    public var confidence: Float
    /// Measured ramp incline in degrees, from the LiDAR surface under it.
    public var slopeDegrees: Float?
    /// A staff member has to operate it or help through it, e.g. an attendant-run lift.
    public var requiresAssistance: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String? = nil,
        position: SIMD3<Float>,
        source: Source,
        confidence: Float,
        slopeDegrees: Float? = nil,
        requiresAssistance: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.title
        self.position = position
        self.source = source
        self.confidence = confidence
        self.slopeDegrees = slopeDegrees
        self.requiresAssistance = requiresAssistance
    }

    public var floorPoint: SIMD2<Float> { SIMD2(position.x, position.z) }

    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    /// Ramps above the supported incline are excluded from wheelchair routes.
    public var isTooSteep: Bool {
        guard kind == .ramp, let slopeDegrees else { return false }
        return slopeDegrees > Self.maximumRampSlope
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, position, source, confidence, slopeDegrees, requiresAssistance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: kind,
            // Older maps may lack newer fields; fall back to defaults.
            name: try container.decodeIfPresent(String.self, forKey: .name),
            position: try container.decode(SIMD3<Float>.self, forKey: .position),
            source: try container.decode(Source.self, forKey: .source),
            confidence: try container.decode(Float.self, forKey: .confidence),
            slopeDegrees: try container.decodeIfPresent(Float.self, forKey: .slopeDegrees),
            requiresAssistance: try container.decodeIfPresent(Bool.self, forKey: .requiresAssistance) ?? false
        )
    }
}
