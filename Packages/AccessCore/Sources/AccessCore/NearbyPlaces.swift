import Foundation
import simd

/// A "what's around here" query for the server's `POST /scans/{id}/nearby`. Positions are in the
/// scan's ARKit frame (meters, +Y up), the same space as `VenueMap`.
public struct NearbySearch: Encodable, Equatable, Sendable {
    public var origin: SIMD3<Float>
    public var query: String?
    public var radiusMeters: Float
    public var limit: Int
    /// The viewer's facing, clockwise degrees in the response's bearing reference.
    public var headingDegrees: Double?

    public init(origin: SIMD3<Float>, query: String? = nil, radiusMeters: Float = 200, limit: Int = 40,
                headingDegrees: Double? = nil) {
        self.origin = origin
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed?.isEmpty == false ? String(trimmed!.prefix(120)) : nil
        self.radiusMeters = min(max(radiusMeters, 1), 5000)
        self.limit = min(max(limit, 1), 100)
        self.headingDegrees = headingDegrees.flatMap { $0.isFinite ? $0 : nil }
    }

    public var isValid: Bool { origin.x.isFinite && origin.y.isFinite && origin.z.isFinite }

    private enum CodingKeys: String, CodingKey {
        case at, query, radiusMeters = "radius_m", limit, headingDegrees = "heading_degrees"
    }
    private struct At: Encodable {
        let position: [Float]
        enum CodingKeys: String, CodingKey { case position = "position_m" }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(At(position: [origin.x, origin.y, origin.z]), forKey: .at)
        try container.encodeIfPresent(query, forKey: .query)
        try container.encode(radiusMeters, forKey: .radiusMeters)
        try container.encode(limit, forKey: .limit)
        try container.encodeIfPresent(headingDegrees, forKey: .headingDegrees)
    }
}

/// Places, signs and floor connectors near a point, ranked by name match and walking distance.
public struct NearbyResults: Decodable, Equatable, Sendable {
    public var results: [NearbyPlace]
    public var totalMatches: Int
    /// `true_north` when the map is georeferenced, else `frame_minus_z`.
    public var bearingReference: String
    public var notices: [String]

    private enum CodingKeys: String, CodingKey {
        case results, totalMatches = "total_matches", bearingReference = "bearing_reference", notices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = (try container.decode(LossyList<NearbyPlace>.self, forKey: .results)).elements
        totalMatches = try container.decodeIfPresent(Int.self, forKey: .totalMatches) ?? results.count
        bearingReference = try container.decodeIfPresent(String.self, forKey: .bearingReference) ?? "frame_minus_z"
        notices = try container.decodeIfPresent([String].self, forKey: .notices) ?? []
    }

    /// Pins for the origin's floor, leaving out anything already on `existing` (kept places share IDs
    /// with these results, and a nearby point of the same kind is treated as the same place).
    public func pins(scanID: String, excluding existing: [AccessPoint]) -> [AccessPoint] {
        AccessPoint.newDetections(results.filter { $0.levelDelta == 0 }.map { $0.accessPoint(scanID: scanID) },
                                  existing: existing)
    }
}

public struct NearbyPlace: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    /// `place`, `sign`, `connector`, `door` or `hazard`.
    public var kind: String
    public var category: String
    public var name: String?
    public var scanID: String
    public var position: SIMD3<Float>
    public var levelID: String
    public var levelDelta: Int
    public var distanceMeters: Float
    public var reachable: Bool
    public var walkingDistanceMeters: Float?
    public var walkingSeconds: Float?
    /// `accessible`, `unverified`, `not_accessible` or `none`.
    public var accessibleRoute: String
    public var bearingDegrees: Float
    public var compass: String?
    public var relativeDirection: String?
    public var servesLevelIDs: [String]
    public var refs: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id, kind, category, name, scanID = "scan_id", position = "position_m", levelID = "level_id"
        case levelDelta = "level_delta", distanceMeters = "distance_m", reachable
        case walkingDistanceMeters = "walking_distance_m", walkingSeconds = "walking_duration_s"
        case accessibleRoute = "accessible_route", bearingDegrees = "bearing_deg", compass
        case relativeDirection = "relative_direction", servesLevelIDs = "serves_level_ids", refs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        category = try container.decode(String.self, forKey: .category)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        scanID = try container.decode(String.self, forKey: .scanID)
        let values = try container.decode([Float].self, forKey: .position)
        guard values.count == 3, values.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(forKey: .position, in: container, debugDescription: "Invalid position.")
        }
        position = SIMD3(values[0], values[1], values[2])
        levelID = try container.decode(String.self, forKey: .levelID)
        levelDelta = try container.decodeIfPresent(Int.self, forKey: .levelDelta) ?? 0
        distanceMeters = try container.decode(Float.self, forKey: .distanceMeters)
        reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? false
        walkingDistanceMeters = try container.decodeIfPresent(Float.self, forKey: .walkingDistanceMeters)
        walkingSeconds = try container.decodeIfPresent(Float.self, forKey: .walkingSeconds)
        accessibleRoute = try container.decodeIfPresent(String.self, forKey: .accessibleRoute) ?? "none"
        bearingDegrees = try container.decodeIfPresent(Float.self, forKey: .bearingDegrees) ?? 0
        compass = try container.decodeIfPresent(String.self, forKey: .compass)
        relativeDirection = try container.decodeIfPresent(String.self, forKey: .relativeDirection)
        servesLevelIDs = try container.decodeIfPresent([String].self, forKey: .servesLevelIDs) ?? []
        refs = try container.decodeIfPresent([String: String].self, forKey: .refs) ?? [:]
    }

    /// The worker record this result came from (a place ID for places).
    public var sourceID: String {
        refs["place_id"] ?? refs["sign_id"] ?? refs["connector_id"] ?? refs["door_id"] ?? refs["hazard_id"] ?? id
    }

    public var title: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return category.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// A browse pin at the measured spot. Places use the same ID as a kept analysis place.
    public func accessPoint(scanID fallbackScanID: String) -> AccessPoint {
        let scan = scanID.isEmpty ? fallbackScanID : scanID
        let placeID = kind == "place" ? sourceID : id
        return AccessPoint(
            id: AccessPoint.detectedID(scanID: scan, placeID: placeID),
            kind: ScanAnalysis.Place.Category(rawValue: category)?.accessPointKind ?? .destination,
            name: title, position: position, source: .detected, confidence: 0.5
        )
    }

    /// Where this is relative to someone at `origin` facing `headingRadians` (clockwise from −z,
    /// the map frame's forward axis, as `NavigationController` reports it).
    public func relativeDirection(from origin: SIMD2<Float>, headingRadians: Float) -> String? {
        let offset = SIMD2(position.x, position.z) - origin
        guard simd_length(offset) > 0.5, headingRadians.isFinite else { return nil }
        let bearing = atan2(offset.x, -offset.y)
        var turn = (bearing - headingRadians) * 180 / .pi
        turn = turn.truncatingRemainder(dividingBy: 360)
        if turn < 0 { turn += 360 }
        switch turn {
        case ..<30, 330...: return "ahead"
        case ..<150: return "right"
        case ...210: return "behind"
        default: return "left"
        }
    }

    public var summary: String { summary(direction: nil) }

    /// "12 m · NE", "1 floor up · 30 m", or "Not connected · 8 m away". `direction` overrides the
    /// server's facing hint with one computed on the device.
    public func summary(direction: String?) -> String {
        var parts: [String] = []
        if levelDelta != 0 {
            let floors = abs(levelDelta)
            parts.append("\(floors) floor\(floors == 1 ? "" : "s") \(levelDelta > 0 ? "up" : "down")")
        }
        if let walk = walkingDistanceMeters, reachable {
            parts.append("\(Int(walk.rounded())) m")
        } else {
            parts.append("Not connected · \(Int(distanceMeters.rounded())) m away")
        }
        if let direction = direction ?? relativeDirection { parts.append(direction.capitalized) }
        else if let compass { parts.append(compass) }
        return parts.joined(separator: " · ")
    }
}

extension BackendClient {
    /// Searches what is around `search.origin` in an uploaded, processed scan. Returns nil while the
    /// scan has no navigation data yet (not processed, or not uploaded from this device).
    public func nearby(scanID: String, search: NearbySearch) async throws -> NearbyResults? {
        guard search.isValid else { throw BackendClientError.invalidCapture("The search position is not valid.") }
        let body = try JSONEncoder().encode(search)
        let response: Data
        do {
            response = try await send(path: ["scans", scanID, "nearby"], method: "POST", stage: .nearby,
                                      timeout: 20, body: body)
        } catch let error as BackendClientError {
            switch error {
            case .http(409, "navigation_data_missing", _), .http(404, _, _): return nil
            default: throw error
            }
        }
        do { return try JSONDecoder().decode(NearbyResults.self, from: response) }
        catch { throw BackendClientError.invalidResponse("The backend returned nearby places the app could not read.") }
    }
}
