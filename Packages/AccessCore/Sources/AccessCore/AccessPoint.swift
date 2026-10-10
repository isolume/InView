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

    public var id: UUID
    public var kind: Kind
    public var name: String?
    /// Position in the map's coordinates (the scan session's world space), in meters.
    /// x and z span the floor; y is up.
    public var position: SIMD3<Float>
    public var source: Source
    public var confidence: Float

    public init(id: UUID = UUID(), kind: Kind, name: String? = nil, position: SIMD3<Float>, source: Source, confidence: Float) {
        self.id = id
        self.kind = kind
        self.name = name
        self.position = position
        self.source = source
        self.confidence = confidence
    }

    public var floorPoint: SIMD2<Float> { SIMD2(position.x, position.z) }

    public var title: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return kind.title
    }
}
