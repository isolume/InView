import Foundation
import simd

/// Routes from the server's `POST /scans/{id}/routes`: multi-floor paths over the scan's navigation
/// graph, with features and an accessibility screening. Positions are in the scan's ARKit frame,
/// the same space as `VenueMap`.
public struct ServerRoutePlan: Decodable, Sendable {
    public struct Level: Decodable, Sendable {
        public var id: String
        public var elevation: Float
        enum CodingKeys: String, CodingKey { case id, elevation = "elevation_m" }
    }

    public struct Endpoint: Decodable, Sendable {
        public var nodeID: String
        public var position: SIMD3<Float>
        public var levelID: String
        /// How far the requested point was from the graph node the route starts or ends at.
        public var snappedDistance: Float
        enum CodingKeys: String, CodingKey {
            case nodeID = "node_id", position = "position_m", levelID = "level_id", snappedDistance = "snapped_distance_m"
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            nodeID = try c.decode(String.self, forKey: .nodeID)
            position = try decodePoint(c, .position)
            levelID = try c.decode(String.self, forKey: .levelID)
            snappedDistance = try c.decodeIfPresent(Float.self, forKey: .snappedDistance) ?? 0
        }
    }

    public struct Unreachable: Decodable, Sendable {
        public var profile: String
        public var reason: String
    }

    public var levels: [Level]
    public var origin: Endpoint
    public var destination: Endpoint
    public var routes: [ServerRoute]
    public var unreachable: [Unreachable]

    /// The server floor matching a measured floor height (the nearest level elevation).
    public func levelID(forFloorY floorY: Float) -> String? {
        levels.min { abs($0.elevation - floorY) < abs($1.elevation - floorY) }?.id
    }
}

public struct ServerRoute: Decodable, Sendable, Identifiable {
    public struct Issue: Decodable, Sendable {
        public var featureID: String?
        public var reason: String
        enum CodingKeys: String, CodingKey { case featureID = "feature_id", reason }
    }

    public struct Accessibility: Decodable, Sendable {
        /// `accessible`, `not_accessible` or `unverified`.
        public var status: String
        public var blocking: [Issue]
        public var unverified: [Issue]
    }

    public struct Feature: Decodable, Sendable, Identifiable {
        public var id: String
        public var type: String
        public var position: SIMD3<Float>
        public var levelID: String
        public var accessible: Bool?
        public var name: String?
        enum CodingKeys: String, CodingKey {
            case id, type, position = "position_m", levelID = "level_id", accessible, name
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            type = try c.decode(String.self, forKey: .type)
            position = try decodePoint(c, .position)
            levelID = try c.decode(String.self, forKey: .levelID)
            accessible = try c.decodeIfPresent(Bool.self, forKey: .accessible)
            name = try c.decodeIfPresent(String.self, forKey: .name)
        }
    }

    public struct Leg: Decodable, Sendable {
        /// `walk` or `connector`.
        public var type: String
        public var levelID: String?
        public var polyline: [SIMD3<Float>]
        public var distance: Float
        enum CodingKeys: String, CodingKey {
            case type, levelID = "level_id", polyline = "polyline_m", distance = "distance_m"
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            levelID = try c.decodeIfPresent(String.self, forKey: .levelID)
            let raw = try c.decodeIfPresent([[Float]].self, forKey: .polyline) ?? []
            polyline = try raw.map { values in
                guard values.count == 3, values.allSatisfy(\.isFinite) else {
                    throw DecodingError.dataCorruptedError(forKey: .polyline, in: c, debugDescription: "Invalid point.")
                }
                return SIMD3(values[0], values[1], values[2])
            }
            distance = try c.decodeIfPresent(Float.self, forKey: .distance) ?? Polyline.length(of: polyline.map { SIMD2($0.x, $0.z) })
        }
    }

    public struct Step: Decodable, Sendable {
        public var maneuver: String
        public var instruction: String
        public var distance: Float
        public var featureIDs: [String]
        enum CodingKeys: String, CodingKey {
            case maneuver, instruction, distance = "distance_m", featureIDs = "feature_ids"
        }
    }

    public var id: String
    public var labels: [String]
    public var distance: Float
    public var duration: Float
    public var levelChanges: Int
    public var accessibility: Accessibility
    public var features: [Feature]
    public var legs: [Leg]
    public var steps: [Step]

    enum CodingKeys: String, CodingKey {
        case id, labels, distance = "distance_m", duration = "duration_s", levelChanges = "level_changes"
        case accessibility, features, legs, steps
    }
}

private func decodePoint<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> SIMD3<Float> {
    let values = try container.decode([Float].self, forKey: key)
    guard values.count == 3, values.allSatisfy(\.isFinite) else {
        throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid position.")
    }
    return SIMD3(values[0], values[1], values[2])
}

/// The request body for `POST /scans/{id}/routes` between two map positions, or to a server place.
public struct ServerRouteRequest: Encodable, Sendable {
    public enum Target: Sendable {
        case position(SIMD3<Float>)
        case place(String)
    }

    public var from: SIMD3<Float>
    public var to: Target
    public var profiles: [String]

    public init(from: SIMD3<Float>, to: Target, profiles: [String] = ["fastest", "accessible"]) {
        self.from = from; self.to = to; self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey { case from, to, profiles }
    private struct Point: Encodable {
        var position: [Float]
        enum CodingKeys: String, CodingKey { case position = "position_m" }
    }
    private struct Place: Encodable {
        var placeID: String
        enum CodingKeys: String, CodingKey { case placeID = "place_id" }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Point(position: [from.x, from.y, from.z]), forKey: .from)
        switch to {
        case .position(let p): try c.encode(Point(position: [p.x, p.y, p.z]), forKey: .to)
        case .place(let id): try c.encode(Place(placeID: id), forKey: .to)
        }
        try c.encode(profiles, forKey: .profiles)
    }
}

extension BackendClient {
    /// Server routes for an uploaded, processed scan. Returns nil when the scan has no navigation
    /// data yet; a `no_route` answer throws, like any other server refusal.
    public func routes(scanID: String, request: ServerRouteRequest) async throws -> ServerRoutePlan? {
        let response: Data
        do {
            response = try await send(path: ["scans", scanID, "routes"], method: "POST", stage: .nearby,
                                      timeout: 20, body: JSONEncoder().encode(request))
        } catch let error as BackendClientError {
            if case .http(409, "navigation_data_missing", _) = error { return nil }
            throw error
        }
        do { return try JSONDecoder().decode(ServerRoutePlan.self, from: response) }
        catch { throw BackendClientError.invalidResponse("The backend returned routes the app could not read.") }
    }
}
