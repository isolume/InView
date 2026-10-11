import Foundation

/// Mapped connectivity between separately measured map frames. A connector never implies that
/// coordinates in its source and destination scans share an origin or orientation.
public struct BuildingRouteGraph: Codable, Equatable, Sendable {
    public static let maximumNodes = 10_000
    public static let maximumEdges = 30_000
    public static let maximumPathPoints = 100_000
    public var schemaVersion: Int
    public var id: String
    public var nodes: [BuildingRouteNode]
    public var edges: [BuildingRouteEdge]
    public var metadata: [String: JSONValue]

    public var venueID: String? {
        if case .string(let id) = metadata["venue_id"] { return id }
        return nil
    }
    public var isDemo: Bool { metadata["demo_only"] == .bool(true) }
    public func node(id: String) -> BuildingRouteNode? { nodes.first { $0.id == id } }

    public init(schemaVersion: Int = 1, id: String, nodes: [BuildingRouteNode], edges: [BuildingRouteEdge],
                metadata: [String: JSONValue] = [:]) {
        self.schemaVersion = schemaVersion; self.id = id; self.nodes = nodes; self.edges = edges; self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", id, nodes, edges, metadata }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        nodes = try values.decode([BuildingRouteNode].self, forKey: .nodes)
        edges = try values.decode([BuildingRouteEdge].self, forKey: .edges)
        metadata = try values.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    }

    /// Pass the explicit venue and graph identities when loading a graph for a building. Metadata
    /// is an association, not proof of map alignment or real-world accessibility.
    public func validate(expectedGraphID: String? = nil, venueID expectedVenueID: String? = nil,
                         allowDemo: Bool = false) throws {
        guard schemaVersion == 1, Self.validID(id), nodes.count <= Self.maximumNodes,
              edges.count <= Self.maximumEdges, !nodes.isEmpty,
              expectedGraphID.map({ $0 == id }) ?? true else { throw BuildingRouteError.invalidGraph }
        if let expectedVenueID {
            guard Self.validID(expectedVenueID), venueID == expectedVenueID else { throw BuildingRouteError.wrongBuilding }
        }
        if let marker = metadata["demo_only"], marker != .bool(true), marker != .bool(false) {
            throw BuildingRouteError.invalidGraph
        }
        guard !isDemo || allowDemo else { throw BuildingRouteError.demoGraph }
        var remainingMetadata = 2_048
        guard Self.validMetadata(.object(metadata), depth: 0, remaining: &remainingMetadata) else {
            throw BuildingRouteError.invalidGraph
        }
        var lookup: [String: BuildingRouteNode] = [:]
        for node in nodes {
            guard Self.validID(node.id), Self.validID(node.mapID), Self.validID(node.floorID),
                  node.position.isValid, node.label.map({ $0.count <= 512 }) ?? true,
                  lookup.updateValue(node, forKey: node.id) == nil else { throw BuildingRouteError.invalidGraph }
        }
        var edgeIDs: Set<String> = []
        var pointCount = 0
        for edge in edges {
            guard Self.validID(edge.id), edgeIDs.insert(edge.id).inserted,
                  let from = lookup[edge.from], let to = lookup[edge.to],
                  edge.minimumClearWidthMeters.map({ $0.isFinite && $0 > 0 }) ?? true,
                  edge.maximumSlope.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw BuildingRouteError.invalidGraph }
            switch edge.segment {
            case let .surface(mapID, floorID, points):
                pointCount += points.count
                guard pointCount <= Self.maximumPathPoints, points.count >= 2,
                      mapID == from.mapID, mapID == to.mapID, floorID == from.floorID, floorID == to.floorID,
                      points.allSatisfy(\.isValid), points[0].distance(to: from.position) <= 0.05,
                      points[points.count - 1].distance(to: to.position) <= 0.05,
                      edge.segment.lengthMeters.isFinite else { throw BuildingRouteError.invalidGraph }
            case let .transition(connectorID, kind, seconds):
                guard Self.validID(connectorID), seconds.isFinite, seconds >= 0,
                      !(kind.involvesSteps && edge.stepFree == true) else { throw BuildingRouteError.invalidGraph }
            }
        }
    }

    static func validID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 256
            && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validMetadata(_ value: JSONValue, depth: Int, remaining: inout Int) -> Bool {
        remaining -= 1
        guard remaining >= 0, depth <= 8 else { return false }
        switch value {
        case .null, .bool: return true
        case .number(let number): return number.isFinite
        case .string(let string): return string.utf8.count <= 4_096
        case .array(let values):
            guard values.count <= remaining else { return false }
            return values.allSatisfy { validMetadata($0, depth: depth + 1, remaining: &remaining) }
        case .object(let values):
            guard values.count <= remaining else { return false }
            return values.allSatisfy { $0.key.utf8.count <= 256 && validMetadata($0.value, depth: depth + 1, remaining: &remaining) }
        }
    }
}

public struct BuildingRoutePoint3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    var isValid: Bool { x.isFinite && y.isFinite && z.isFinite && max(abs(x), abs(y), abs(z)) <= 1_000_000 }
    public func distance(to other: Self) -> Double { hypot(hypot(x - other.x, y - other.y), z - other.z) }
}

public struct BuildingRouteNode: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var mapID: String
    public var floorID: String
    public var x: Double
    public var y: Double
    public var z: Double
    public var label: String?
    public var title: String { label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? id }
    public var position: BuildingRoutePoint3 { .init(x: x, y: y, z: z) }
    public init(id: String, mapID: String, floorID: String, x: Double, y: Double, z: Double, label: String? = nil) {
        self.id = id; self.mapID = mapID; self.floorID = floorID; self.x = x; self.y = y; self.z = z; self.label = label
    }
    enum CodingKeys: String, CodingKey { case id, mapID = "map_id", floorID = "floor_id", x, y, z, label }
}

public enum BuildingConnectorKind: String, Codable, Sendable {
    case elevator, stairs, escalator, ramp
    public var title: String {
        switch self { case .elevator: "Elevator"; case .stairs: "Stairs"; case .escalator: "Escalator"; case .ramp: "Ramp" }
    }
    public var involvesSteps: Bool { self == .stairs || self == .escalator }
}

public enum BuildingEdgeAvailability: String, Codable, Sendable { case available, closed, unknown }

public struct BuildingRouteEdge: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var stepFree: Bool?
    public var availability: BuildingEdgeAvailability
    public var minimumClearWidthMeters: Double?
    public var maximumSlope: Double?
    public var segment: BuildingRouteGeometry
    public init(id: String, from: String, to: String, stepFree: Bool? = nil,
                availability: BuildingEdgeAvailability = .unknown, minimumClearWidthMeters: Double? = nil,
                maximumSlope: Double? = nil, segment: BuildingRouteGeometry) {
        self.id = id; self.from = from; self.to = to; self.stepFree = stepFree; self.availability = availability
        self.minimumClearWidthMeters = minimumClearWidthMeters; self.maximumSlope = maximumSlope; self.segment = segment
    }
    enum CodingKeys: String, CodingKey {
        case id, from, to, stepFree = "step_free", availability, minimumClearWidthMeters = "minimum_clear_width_m"
        case maximumSlope = "maximum_slope", segment
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); from = try values.decode(String.self, forKey: .from)
        to = try values.decode(String.self, forKey: .to)
        stepFree = try values.decodeIfPresent(Bool.self, forKey: .stepFree)
        availability = try values.decodeIfPresent(BuildingEdgeAvailability.self, forKey: .availability) ?? .unknown
        minimumClearWidthMeters = try values.decodeIfPresent(Double.self, forKey: .minimumClearWidthMeters)
        maximumSlope = try values.decodeIfPresent(Double.self, forKey: .maximumSlope)
        segment = try values.decode(BuildingRouteGeometry.self, forKey: .segment)
    }
}

public enum BuildingRouteGeometry: Codable, Equatable, Sendable {
    case surface(mapID: String, floorID: String, pathPoints: [BuildingRoutePoint3])
    case transition(connectorID: String, kind: BuildingConnectorKind, estimatedSeconds: Double)

    /// Connectors have no shared-frame polyline; their duration comes from the reviewed trip estimate.
    public var lengthMeters: Double {
        guard case .surface(_, _, let points) = self else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    enum CodingKeys: String, CodingKey {
        case type, mapID = "map_id", floorID = "floor_id", pathPoints = "path_points"
        case connectorID = "connector_id", kind, estimatedSeconds = "estimated_seconds"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "surface":
            guard !values.contains(.connectorID), !values.contains(.kind), !values.contains(.estimatedSeconds) else {
                throw BuildingRouteError.invalidGraph
            }
            self = .surface(mapID: try values.decode(String.self, forKey: .mapID),
                            floorID: try values.decode(String.self, forKey: .floorID),
                            pathPoints: try values.decode([BuildingRoutePoint3].self, forKey: .pathPoints))
        case "transition":
            guard !values.contains(.mapID), !values.contains(.floorID), !values.contains(.pathPoints) else {
                throw BuildingRouteError.invalidGraph
            }
            self = .transition(connectorID: try values.decode(String.self, forKey: .connectorID),
                               kind: try values.decode(BuildingConnectorKind.self, forKey: .kind),
                               estimatedSeconds: try values.decode(Double.self, forKey: .estimatedSeconds))
        default: throw BuildingRouteError.invalidGraph
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .surface(mapID, floorID, points):
            try values.encode("surface", forKey: .type); try values.encode(mapID, forKey: .mapID)
            try values.encode(floorID, forKey: .floorID); try values.encode(points, forKey: .pathPoints)
        case let .transition(connectorID, kind, seconds):
            try values.encode("transition", forKey: .type); try values.encode(connectorID, forKey: .connectorID)
            try values.encode(kind, forKey: .kind); try values.encode(seconds, forKey: .estimatedSeconds)
        }
    }
}

public enum BuildingRouteError: Error, LocalizedError, Equatable {
    case invalidGraph, wrongBuilding, demoGraph, invalidRequest, invalidRoute
    public var errorDescription: String? {
        switch self {
        case .invalidGraph: "The building’s route map could not be read. Please refresh it."
        case .wrongBuilding: "This route map belongs to another building."
        case .demoGraph: "This example route map can only be opened in the demo."
        case .invalidRequest: "Choose a start and destination from this building."
        case .invalidRoute: "The route map has changed or the directions could not be verified. Refresh and try again."
        }
    }
}
