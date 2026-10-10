import Foundation

public struct BuildingRouteRequirements: Codable, Equatable, Sendable {
    public var requiresStepFree: Bool
    public var minimumClearWidthMeters: Double?
    /// Absolute rise/run, matching the backend; this is not an angle in degrees.
    public var maximumSlope: Double?
    public init(requiresStepFree: Bool = false, minimumClearWidthMeters: Double? = nil, maximumSlope: Double? = nil) {
        self.requiresStepFree = requiresStepFree
        self.minimumClearWidthMeters = minimumClearWidthMeters; self.maximumSlope = maximumSlope
    }
    enum CodingKeys: String, CodingKey {
        case requiresStepFree = "requires_step_free", minimumClearWidthMeters = "minimum_clear_width_m", maximumSlope = "maximum_slope"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requiresStepFree = try values.decodeIfPresent(Bool.self, forKey: .requiresStepFree) ?? false
        minimumClearWidthMeters = try values.decodeIfPresent(Double.self, forKey: .minimumClearWidthMeters)
        maximumSlope = try values.decodeIfPresent(Double.self, forKey: .maximumSlope)
    }

    public func allows(_ edge: BuildingRouteEdge) -> Bool {
        guard edge.availability == .available else { return false }
        if requiresStepFree {
            guard edge.stepFree == true else { return false }
            if case .transition(_, let kind, _) = edge.segment, kind.involvesSteps { return false }
        }
        if let minimumClearWidthMeters {
            guard let width = edge.minimumClearWidthMeters, width >= minimumClearWidthMeters else { return false }
        }
        if let maximumSlope {
            guard let slope = edge.maximumSlope, slope <= maximumSlope else { return false }
        }
        return true
    }
}

public struct BuildingRouteRequest: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var requirements: BuildingRouteRequirements
    public var movementSpeedMetersPerSecond: Double

    public init(from: String, to: String, preference: RoutePreference) {
        self.from = from; self.to = to; self.movementSpeedMetersPerSecond = 1
        switch preference {
        case .stepFree: requirements = .init(requiresStepFree: true, minimumClearWidthMeters: 0.9, maximumSlope: 1.0 / 12.0)
        case .fastest: requirements = .init()
        }
    }
    enum CodingKeys: String, CodingKey {
        case from, to, requirements, movementSpeedMetersPerSecond = "movement_speed_mps"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        from = try values.decode(String.self, forKey: .from); to = try values.decode(String.self, forKey: .to)
        requirements = try values.decodeIfPresent(BuildingRouteRequirements.self, forKey: .requirements) ?? .init()
        movementSpeedMetersPerSecond = try values.decodeIfPresent(Double.self, forKey: .movementSpeedMetersPerSecond) ?? 1
    }
    public func validate(graph: BuildingRouteGraph) throws {
        guard graph.node(id: from) != nil, graph.node(id: to) != nil,
              movementSpeedMetersPerSecond.isFinite, movementSpeedMetersPerSecond > 0,
              requirements.minimumClearWidthMeters.map({ $0.isFinite && $0 > 0 }) ?? true,
              requirements.maximumSlope.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw BuildingRouteError.invalidRequest
        }
    }
}

public struct BuildingRouteSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: String { edgeID }
    public var edgeID: String
    public var from: String
    public var to: String
    public var fromMapID: String
    public var toMapID: String
    public var fromFloorID: String
    public var toFloorID: String
    public var geometry: BuildingRouteGeometry
    public init(edgeID: String, from: String, to: String, fromMapID: String, toMapID: String,
                fromFloorID: String, toFloorID: String, geometry: BuildingRouteGeometry) {
        self.edgeID = edgeID; self.from = from; self.to = to; self.fromMapID = fromMapID; self.toMapID = toMapID
        self.fromFloorID = fromFloorID; self.toFloorID = toFloorID; self.geometry = geometry
    }
    enum CodingKeys: String, CodingKey {
        case edgeID = "edge_id", from, to, fromMapID = "from_map_id", toMapID = "to_map_id"
        case fromFloorID = "from_floor_id", toFloorID = "to_floor_id"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        edgeID = try values.decode(String.self, forKey: .edgeID)
        from = try values.decode(String.self, forKey: .from); to = try values.decode(String.self, forKey: .to)
        fromMapID = try values.decode(String.self, forKey: .fromMapID); toMapID = try values.decode(String.self, forKey: .toMapID)
        fromFloorID = try values.decode(String.self, forKey: .fromFloorID); toFloorID = try values.decode(String.self, forKey: .toFloorID)
        geometry = try BuildingRouteGeometry(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(edgeID, forKey: .edgeID); try values.encode(from, forKey: .from); try values.encode(to, forKey: .to)
        try values.encode(fromMapID, forKey: .fromMapID); try values.encode(toMapID, forKey: .toMapID)
        try values.encode(fromFloorID, forKey: .fromFloorID); try values.encode(toFloorID, forKey: .toFloorID)
        try geometry.encode(to: encoder)
    }
}

public struct BuildingRoute: Codable, Equatable, Sendable {
    public var graphID: String
    public var schemaVersion: Int
    public var nodeIDs: [String]
    public var segments: [BuildingRouteSegment]
    public var estimatedSeconds: Double
    public var requirements: BuildingRouteRequirements
    public init(graphID: String, schemaVersion: Int = 1, nodeIDs: [String], segments: [BuildingRouteSegment],
                estimatedSeconds: Double, requirements: BuildingRouteRequirements) {
        self.graphID = graphID; self.schemaVersion = schemaVersion; self.nodeIDs = nodeIDs; self.segments = segments
        self.estimatedSeconds = estimatedSeconds; self.requirements = requirements
    }
    enum CodingKeys: String, CodingKey {
        case graphID = "graph_id", schemaVersion = "schema_version", nodeIDs = "node_ids", segments
        case estimatedSeconds = "estimated_seconds", requirements
    }

    /// Validate returned legs against the graph snapshot used to choose the endpoints. Never accept
    /// a relaxed profile, a stale/mutated edge, or a ground polyline joining different scan frames.
    public func validate(graph: BuildingRouteGraph, request: BuildingRouteRequest) throws {
        try graph.validate(allowDemo: true)
        try request.validate(graph: graph)
        guard graphID == graph.id, schemaVersion == graph.schemaVersion,
              requirements == request.requirements, estimatedSeconds.isFinite, estimatedSeconds >= 0,
              segments.count < BuildingRouteGraph.maximumNodes,
              nodeIDs.count == segments.count + 1, nodeIDs.first == request.from, nodeIDs.last == request.to,
              Set(nodeIDs).count == nodeIDs.count else { throw BuildingRouteError.invalidRoute }
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let edges = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0) })
        var seconds = 0.0
        for (index, segment) in segments.enumerated() {
            guard let edge = edges[segment.edgeID], let from = nodes[segment.from], let to = nodes[segment.to],
                  segment.from == nodeIDs[index], segment.to == nodeIDs[index + 1],
                  edge.from == segment.from, edge.to == segment.to, edge.segment == segment.geometry,
                  segment.fromMapID == from.mapID, segment.toMapID == to.mapID,
                  segment.fromFloorID == from.floorID, segment.toFloorID == to.floorID,
                  request.requirements.allows(edge) else { throw BuildingRouteError.invalidRoute }
            switch edge.segment {
            case .surface: seconds += edge.segment.lengthMeters / request.movementSpeedMetersPerSecond
            case .transition(_, _, let estimate): seconds += estimate
            }
        }
        guard seconds.isFinite, abs(estimatedSeconds - seconds) <= max(0.01, seconds * 1e-6) else {
            throw BuildingRouteError.invalidRoute
        }
    }
}
