import Foundation
import Testing
@testable import AccessCore

private func buildingGraphExample() throws -> BuildingRouteGraph {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { root = root.deletingLastPathComponent() }
    var graph = try JSONDecoder().decode(BuildingRouteGraph.self, from: Data(contentsOf: root.appendingPathComponent("backend/examples/graph.json")))
    graph.metadata["venue_id"] = .string("demo-building")
    return graph
}

/// Construct validation inputs from existing edges; this helper does not choose or optimize a route.
/// The live backend tests exercise which path wins. No prerecorded route result ships in the app.
private func candidateRoute(graph: BuildingRouteGraph, edgeIDs: [String], request: BuildingRouteRequest) throws -> BuildingRoute {
    let edges = try edgeIDs.map { id in try #require(graph.edges.first { $0.id == id }) }
    var nodes = [request.from]
    var seconds = 0.0
    let segments = try edges.map { edge in
        let from = try #require(graph.node(id: edge.from)), to = try #require(graph.node(id: edge.to))
        nodes.append(to.id)
        switch edge.segment {
        case .surface: seconds += edge.segment.lengthMeters / request.movementSpeedMetersPerSecond
        case .transition(_, _, let estimate): seconds += estimate
        }
        return BuildingRouteSegment(edgeID: edge.id, from: edge.from, to: edge.to,
                                    fromMapID: from.mapID, toMapID: to.mapID,
                                    fromFloorID: from.floorID, toFloorID: to.floorID, geometry: edge.segment)
    }
    return BuildingRoute(graphID: graph.id, nodeIDs: nodes, segments: segments,
                         estimatedSeconds: seconds, requirements: request.requirements)
}

@Test func buildingRouteRequestsMapPreferencesWithoutLeavingStepFreeConstraintsOnFastest() throws {
    let stepFree = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .stepFree)
    #expect(stepFree.requirements.requiresStepFree)
    #expect(stepFree.requirements.minimumClearWidthMeters == 0.9)
    #expect(stepFree.requirements.maximumSlope == 1.0 / 12.0)
    #expect(stepFree.movementSpeedMetersPerSecond == 1)
    let fastest = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .fastest)
    #expect(!fastest.requirements.requiresStepFree)
    #expect(fastest.requirements.minimumClearWidthMeters == nil)
    #expect(fastest.requirements.maximumSlope == nil)
    #expect(fastest.movementSpeedMetersPerSecond == 1)
    let data = try JSONEncoder().encode(stepFree)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let requirements = try #require(json["requirements"] as? [String: Any])
    #expect(requirements["requires_step_free"] as? Bool == true)
    #expect(requirements["minimum_clear_width_m"] as? Double == 0.9)
    #expect(json["movement_speed_mps"] as? Double == 1)
    #expect(try JSONDecoder().decode(BuildingRouteRequest.self, from: data) == stepFree)
    let defaults = try JSONDecoder().decode(BuildingRouteRequest.self, from: Data(#"{"from":"entrance","to":"room-204"}"#.utf8))
    #expect(defaults == fastest)
}

@Test func buildingRouteGraphMatchesRustFixtureAndKeepsCoordinateFramesSeparate() throws {
    let graph = try buildingGraphExample()
    try graph.validate(expectedGraphID: "demo-building", venueID: "demo-building", allowDemo: true)
    #expect(graph.node(id: "elevator-ground")?.mapID == "ground-scan")
    #expect(graph.node(id: "elevator-upper")?.mapID == "upper-scan")
    #expect(graph.node(id: "elevator-ground")?.title == "Elevator A")
    #expect(try JSONDecoder().decode(BuildingRouteGraph.self, from: JSONEncoder().encode(graph)) == graph)
    #expect(throws: BuildingRouteError.demoGraph) { try graph.validate(venueID: "demo-building") }
    #expect(throws: BuildingRouteError.wrongBuilding) { try graph.validate(venueID: "student-center-east", allowDemo: true) }
    #expect(throws: BuildingRouteError.invalidGraph) { try graph.validate(expectedGraphID: "another", allowDemo: true) }
}

@Test func buildingRouteGraphRejectsUnknownVenueAndMalformedDemoMetadata() throws {
    var graph = try buildingGraphExample()
    graph.metadata.removeValue(forKey: "venue_id")
    #expect(throws: BuildingRouteError.wrongBuilding) { try graph.validate(venueID: "demo-building", allowDemo: true) }
    graph.metadata["demo_only"] = .string("false")
    #expect(throws: BuildingRouteError.invalidGraph) { try graph.validate(allowDemo: true) }
}

@Test func buildingRouteGraphRejectsMalformedUnboundedAndCrossFrameSurfaceGeometry() throws {
    let original = try buildingGraphExample()
    var malformed = original
    malformed.nodes[0].x = .nan
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
    malformed = original
    malformed.nodes.append(original.nodes[0])
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
    malformed = original
    malformed.edges[0].to = "missing"
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
    malformed = original
    malformed.edges[0].segment = .surface(mapID: "upper-scan", floorID: "upper", pathPoints: [original.nodes[0].position, original.nodes[1].position])
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
    malformed = original
    malformed.nodes = Array(repeating: original.nodes[0], count: BuildingRouteGraph.maximumNodes + 1)
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
    malformed = original
    malformed.edges[0].maximumSlope = -.infinity
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
    malformed = original
    malformed.edges[0].segment = .surface(mapID: "ground-scan", floorID: "ground", pathPoints: Array(repeating: original.nodes[0].position, count: BuildingRouteGraph.maximumPathPoints + 1))
    #expect(throws: BuildingRouteError.invalidGraph) { try malformed.validate(allowDemo: true) }
}

@Test func buildingRouteGeometryNeverDecodesAnInventedGroundPathForTransition() throws {
    let ambiguous = #"{"type":"transition","connector_id":"lift","kind":"elevator","estimated_seconds":20,"path_points":[]}"#
    #expect(throws: (any Error).self) { try JSONDecoder().decode(BuildingRouteGeometry.self, from: Data(ambiguous.utf8)) }
    let ramp = BuildingRouteGeometry.transition(connectorID: "ramp-a", kind: .ramp, estimatedSeconds: 45)
    #expect(try JSONDecoder().decode(BuildingRouteGeometry.self, from: JSONEncoder().encode(ramp)) == ramp)
}

@Test func buildingRouteValidationAcceptsExactGraphLegsAndCodableFlattenedRustShape() throws {
    let graph = try buildingGraphExample()
    let request = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .stepFree)
    let route = try candidateRoute(graph: graph, edgeIDs: ["ground-corridor", "elevator-a-ride", "upper-corridor"], request: request)
    try route.validate(graph: graph, request: request)
    let data = try JSONEncoder().encode(route)
    #expect(try JSONDecoder().decode(BuildingRoute.self, from: data) == route)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let segments = try #require(json["segments"] as? [[String: Any]])
    #expect(segments[1]["type"] as? String == "transition")
    #expect(segments[1]["geometry"] == nil)
    #expect(segments[1]["path_points"] == nil)
    #expect(segments[0]["map_id"] as? String == "ground-scan")
    #expect(segments[2]["map_id"] as? String == "upper-scan")
}

@Test func buildingRouteValidationRejectsRelaxedRequirementEchoAndStairFallback() throws {
    let graph = try buildingGraphExample()
    let stepFree = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .stepFree)
    let fastest = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .fastest)
    var stairs = try candidateRoute(graph: graph, edgeIDs: ["stairs-shortcut"], request: fastest)
    try stairs.validate(graph: graph, request: fastest)
    #expect(throws: BuildingRouteError.invalidRoute) { try stairs.validate(graph: graph, request: stepFree) }
    stairs.requirements = stepFree.requirements // Even a falsely strict echo cannot make stairs eligible.
    #expect(throws: BuildingRouteError.invalidRoute) { try stairs.validate(graph: graph, request: stepFree) }
}

@Test func buildingRouteValidationRejectsUnavailableUnknownAndInsufficientMeasurements() throws {
    let original = try buildingGraphExample()
    let request = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .stepFree)
    let route = try candidateRoute(graph: original, edgeIDs: ["ground-corridor", "elevator-a-ride", "upper-corridor"], request: request)
    for availability in [BuildingEdgeAvailability.closed, .unknown] {
        var graph = original
        graph.edges[1].availability = availability
        #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    }
    var graph = original
    graph.edges[1].stepFree = nil
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    graph = original; graph.edges[1].minimumClearWidthMeters = nil
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    graph = original; graph.edges[1].minimumClearWidthMeters = 0.8
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    graph = original; graph.edges[1].maximumSlope = nil
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    graph = original; graph.edges[1].maximumSlope = 0.09
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
}

@Test func buildingRouteValidationRejectsWrongEndpointsDiscontinuitiesFramesAndStaleEdges() throws {
    let graph = try buildingGraphExample()
    let request = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .stepFree)
    let original = try candidateRoute(graph: graph, edgeIDs: ["ground-corridor", "elevator-a-ride", "upper-corridor"], request: request)
    var route = original; route.graphID = "another-building"
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.nodeIDs[0] = "elevator-ground"
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.segments[1].from = "entrance"
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.segments[1].toMapID = "ground-scan"
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.segments[2].toFloorID = "ground"
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.segments[1].geometry = .transition(connectorID: "another-elevator", kind: .elevator, estimatedSeconds: 25)
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.estimatedSeconds = .infinity
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
    route = original; route.estimatedSeconds += 1
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
}

@Test func buildingRouteValidationHandlesSameNodeWithoutAddingTravel() throws {
    let graph = try buildingGraphExample()
    let request = BuildingRouteRequest(from: "entrance", to: "entrance", preference: .stepFree)
    let route = try candidateRoute(graph: graph, edgeIDs: [], request: request)
    try route.validate(graph: graph, request: request)
    #expect(route.segments.isEmpty)
    var invalid = request; invalid.to = "missing"
    #expect(throws: BuildingRouteError.invalidRequest) { try invalid.validate(graph: graph) }
    invalid = request; invalid.movementSpeedMetersPerSecond = .nan
    #expect(throws: BuildingRouteError.invalidRequest) { try invalid.validate(graph: graph) }
}

@Test func buildingRouteRampConnectorUsesMeasuredEligibilityAndExplicitFloorTransition() throws {
    var graph = try buildingGraphExample()
    graph.edges[1].segment = .transition(connectorID: "ramp-a", kind: .ramp, estimatedSeconds: 45)
    graph.edges[1].maximumSlope = 1.0 / 12.0
    let request = BuildingRouteRequest(from: "entrance", to: "room-204", preference: .stepFree)
    let route = try candidateRoute(graph: graph, edgeIDs: ["ground-corridor", "elevator-a-ride", "upper-corridor"], request: request)
    try route.validate(graph: graph, request: request)
    #expect(route.segments[1].fromFloorID != route.segments[1].toFloorID)
    graph.edges[1].maximumSlope = 0.1
    #expect(throws: BuildingRouteError.invalidRoute) { try route.validate(graph: graph, request: request) }
}
