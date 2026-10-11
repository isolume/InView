import Foundation
import simd
import Testing
@testable import AccessCore

struct ElevatedFloorRoutePlannerTests {
    @Test func preservesElevationsAndUsesElevatorForStepFreeButStairsForFastest() throws {
        let fixture = fixture()
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        let stepFree = try #require(planner.route(from: fixture.start, to: fixture.destination.id))
        let fastest = try #require(planner.route(from: fixture.start, to: fixture.destination.id,
                                               conditions: RoutePreference.fastest.conditions()))
        #expect(stepFree.displayFloor == 1)
        #expect(stepFree.destinationZoneID == "raised")
        #expect(transitions(stepFree).map(\.kind) == [.elevator])
        #expect(transitions(fastest).map(\.kind) == [.stairs])
        #expect(fastest.estimatedSeconds < stepFree.estimatedSeconds)
        #expect(abs(stepFree.estimatedSeconds - Double(stepFree.walkingLength) - 20) < 0.001)
        #expect(stepFree.segments.count == 3)
        for route in [stepFree, fastest] {
            let surfaces = surfaces(route)
            #expect(surfaces.map(\.zoneID) == ["lower", "raised"])
            #expect(surfaces[0].points.allSatisfy { $0.y == 0 })
            #expect(surfaces[1].points.allSatisfy { $0.y == 1.4 })
            #expect(surfaces[0].points.first == fixture.start.position)
            #expect(surfaces[1].points.last == fixture.destination.position)
            let transition = try #require(transitions(route).first)
            #expect(surfaces[0].points.last == transition.from.position)
            #expect(surfaces[1].points.first == transition.to.position)
            #expect(surfaces.allSatisfy { $0.route.unmappedLength == 0 })
        }
    }

    @Test func overlappingZonesNeverConnectWithoutAnExplicitConnector() throws {
        var fixture = fixture()
        fixture.map.connectors = []
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        #expect(planner.route(from: fixture.start, to: fixture.destination.id) == nil)
        #expect(planner.route(from: fixture.start, to: fixture.destination.id,
                              conditions: RouteConditions(preference: .fastest, allowsUnmappedSpace: true)) == nil)
    }

    @Test func elevatorNeedsCurrentAvailabilityAndExplicitStepFreeWidth() throws {
        for variant in 0..<5 {
            var fixture = fixture()
            switch variant {
            case 0: fixture.map.connectors[1].availability = .closed
            case 1: fixture.map.connectors[1].availability = .unknown
            case 2: fixture.map.connectors[1].stepFree = nil
            case 3: fixture.map.connectors[1].minimumClearWidthMeters = nil
            default: fixture.map.connectors[1].minimumClearWidthMeters = 0.8
            }
            let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
            #expect(planner.route(from: fixture.start, to: fixture.destination.id) == nil)
            let fastest = try #require(planner.route(from: fixture.start, to: fixture.destination.id,
                                                     conditions: RoutePreference.fastest.conditions()))
            #expect(transitions(fastest).map(\.kind) == [.stairs])
        }
        let fixture = fixture()
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        #expect(planner.route(from: fixture.start, to: fixture.destination.id,
                              unavailableConnectors: ["lift"]) == nil)
    }

    @Test func verticallyAlignedLandingsKeepAnExplicitTimedTransition() throws {
        var fixture = fixture()
        fixture.map.connectors.removeFirst()
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        let route = try #require(planner.route(from: fixture.start, to: fixture.destination.id))
        let transition = try #require(transitions(route).first)
        #expect(transition.from.floorPoint == transition.to.floorPoint)
        #expect(transition.from.position.y != transition.to.position.y)
        #expect(transition.estimatedSeconds == 20)
        #expect(route.estimatedSeconds > 20)
    }

    @Test func cannotReachALandingBySnappingThroughAWall() throws {
        var fixture = fixture()
        fixture.map.connectors = [fixture.map.connectors[0]]
        let wall = Footprint(kind: .wall, center: [0, 0], size: [0.1, 10], yaw: 0)
        fixture.map.zones[0].map.footprints.append(wall)
        fixture.map.connectors[0].from.position = [0.7, 0, 0]
        // The ordinary destination policy may stop on the near side of a wall within
        // 1.5 m of a point. That policy must never establish a usable connector landing.
        let ordinary = RoutePlanner(map: fixture.map.zones[0].map)
        let landing = AccessPoint(kind: .destination, position: [0.7, 0, 0], source: .manual, confidence: 1)
        #expect(ordinary.route(from: fixture.start.floorPoint, to: landing,
                               conditions: RoutePreference.fastest.conditions()) != nil)
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        #expect(planner.route(from: fixture.start, to: fixture.destination.id,
                              conditions: RoutePreference.fastest.conditions()) == nil)
    }

    @Test func blockedExitCannotChainStraightIntoAnotherConnector() throws {
        var fixture = fixture()
        let destination = fixture.destination
        fixture.map.zones[1].map.points = []
        fixture.map.zones[1].map.footprints.append(Footprint(kind: .obstacle, center: [1, 0], size: [2, 2], yaw: 0))
        fixture.map.zones.append(zone("final", elevation: 2.8, points: [AccessPoint(id: destination.id,
            kind: .destination, position: [3, 2.8, 0], source: .manual, confidence: 1)]))
        fixture.map.connectors = [fixture.map.connectors[0], ElevatedFloorConnector(id: "second-stairs", kind: .stairs,
            from: .init(zoneID: "raised", position: [1, 1.4, 0]),
            to: .init(zoneID: "final", position: [1, 2.8, 0]), availability: .available, estimatedSeconds: 3)]
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        #expect(planner.route(from: fixture.start, to: destination.id, conditions: RoutePreference.fastest.conditions()) == nil)
    }

    @Test func observedFloorGapsStayClosedEvenWhenOrdinaryConditionsAllowUnmappedSpace() throws {
        let target = AccessPoint(kind: .destination, position: [2, 0, 0], source: .manual, confidence: 1)
        var isolated = zone("isolated", elevation: 0, points: [target])
        isolated.map.footprints = [
            Footprint(kind: .floor, center: [-2, 0], size: [2, 2], yaw: 0, bottom: 0),
            Footprint(kind: .floor, center: [2, 0], size: [2, 2], yaw: 0, bottom: 0),
        ]
        let planner = try ElevatedFloorRoutePlanner(map: .init(displayFloor: 1, zones: [isolated], connectors: []))
        #expect(planner.route(from: .init(zoneID: "isolated", position: [-2, 0, 0]), to: target.id,
                              conditions: RouteConditions(allowsUnmappedSpace: true)) == nil)
    }

    @Test func obstaclesAreScopedToTheirActualElevation() throws {
        let fixture = fixture()
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        var conditions = RoutePreference.fastest.conditions()
        conditions.obstacles = [fixture.destination.floorPoint]
        #expect(planner.route(from: fixture.start, to: fixture.destination.id, conditions: conditions) != nil)
        #expect(planner.route(from: fixture.start, to: fixture.destination.id, conditions: conditions,
                              obstaclesByZone: ["raised": [fixture.destination.floorPoint]]) == nil)
    }

    @Test func sameZoneRoutesHaveNoTransitionsAndRejectWrongElevationOrDestination() throws {
        var fixture = fixture()
        let target = AccessPoint(kind: .destination, position: [3, 0, -2], source: .manual, confidence: 1)
        fixture.map.zones[0].map.points = [target]
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        let route = try #require(planner.route(from: fixture.start, to: target.id))
        #expect(transitions(route).isEmpty)
        #expect(surfaces(route).map(\.zoneID) == ["lower"])
        #expect(planner.route(from: .init(zoneID: "lower", position: [-3, 1.4, 0]), to: target.id) == nil)
        #expect(planner.route(from: fixture.start, to: UUID()) == nil)
        #expect(planner.route(from: fixture.start, to: target.id, conditions: RouteConditions(unavailable: [target.id])) == nil)
    }

    @Test func respectsOneWayConnectorDirection() throws {
        var fixture = fixture()
        let target = AccessPoint(kind: .destination, position: [-3, 0, 0], source: .manual, confidence: 1)
        fixture.map.zones[0].map.points = [target]
        fixture.map.connectors = [fixture.map.connectors[0]]
        fixture.map.connectors[0].bidirectional = false
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        let reverseStart = ElevatedFloorLocation(zoneID: "raised", position: [3, 1.4, 0])
        #expect(planner.route(from: reverseStart, to: target.id, conditions: RoutePreference.fastest.conditions()) == nil)
        #expect(planner.route(from: fixture.start, to: fixture.destination.id, conditions: RoutePreference.fastest.conditions()) != nil)
    }

    @Test func rejectsMalformedAndUnboundedMapsBeforeAllocatingGrids() throws {
        for variant in 0..<8 {
            var fixture = fixture()
            switch variant {
            case 0: fixture.map.zones[0].map.floorY = .nan
            case 1: fixture.map.zones[0].map.footprints = []
            case 2: fixture.map.zones[0].map.footprints[0].size = [1_000_000, 1_000_000]
            case 3: fixture.map.zones[0].map.points = [fixture.destination]
            case 4: fixture.map.connectors[0].stepFree = true
            case 5: fixture.map.connectors[0].to.zoneID = "missing"
            case 6: fixture.map.connectors[0].estimatedSeconds = .infinity
            default: fixture.map.zones[0].map.footprints[0].bottom = 1.4
            }
            #expect(throws: (any Error).self) { try ElevatedFloorRoutePlanner(map: fixture.map) }
        }
        var fixture = fixture()
        fixture.map.connectors = Array(repeating: fixture.map.connectors[0], count: ElevatedFloorMap.maximumConnectors + 1)
        #expect(throws: ElevatedFloorMapError.invalidMap) { try fixture.map.validate() }
    }

    @Test func codableMapRetainsNamedZonesConnectorsAndDestinationOwnership() throws {
        let fixture = fixture()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ElevatedFloorMap.self, from: encoder.encode(fixture.map))
        try decoded.validate()
        #expect(decoded.displayFloor == 1)
        #expect(decoded.zones[1].name == "Auditorium landing")
        #expect(decoded.connectors[1].name == "Auditorium elevator")
        #expect(decoded.destinationZones[fixture.destination.id] == "raised")
        #expect(try ElevatedFloorRoutePlanner(map: decoded).route(from: fixture.start, to: fixture.destination.id) != nil)
    }

    @Test func routesBetweenArbitraryPointsWithoutSavedDestinationIDs() throws {
        var fixture = fixture()
        fixture.map.zones[1].map.points = []
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        let target = ElevatedFloorLocation(zoneID: "raised", position: [2.25, 1.4, -1.35])
        let route = try #require(planner.route(from: fixture.start, to: target, destinationName: "Point on the map"))
        #expect(route.destination.position == target.position)
        #expect(route.destination.title == "Point on the map")
        #expect(route.destinationZoneID == target.zoneID)
        #expect(surfaces(route).first?.points.first == fixture.start.position)
        #expect(surfaces(route).last?.points.last == target.position)
        #expect(transitions(route).map(\.kind) == [.elevator])
        let reverse = try #require(planner.route(from: target, to: fixture.start))
        #expect(reverse.destination.position == fixture.start.position)
        #expect(surfaces(reverse).first?.points.first == target.position)
        #expect(surfaces(reverse).last?.points.last == fixture.start.position)
        #expect(planner.route(from: fixture.start, to: .init(zoneID: "raised", position: [2.25, 0, -1.35])) == nil)
        #expect(planner.route(from: fixture.start, to: .init(zoneID: "raised", position: [50, 1.4, 50])) == nil)
    }

    @Test func arbitraryEndpointsMustBeClearInBothDirections() throws {
        var fixture = fixture()
        fixture.map.zones[0].map.footprints.append(Footprint(kind: .wall, center: [0, 0], size: [0.1, 10], yaw: 0))
        fixture.map.connectors = []
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        let onWall = ElevatedFloorLocation(zoneID: "lower", position: [0, 0, 0])
        let beyondWall = ElevatedFloorLocation(zoneID: "lower", position: [0.7, 0, 0])
        #expect(planner.route(from: fixture.start, to: onWall) == nil)
        #expect(planner.route(from: onWall, to: fixture.start) == nil)
        #expect(planner.route(from: fixture.start, to: beyondWall) == nil)
        #expect(planner.route(from: beyondWall, to: fixture.start) == nil)
    }

    @Test func measuredRampSupportsStepFreeTravelInBothDirections() throws {
        let fixture = rampFixture()
        let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
        for (start, target) in [(fixture.start, fixture.target), (fixture.target, fixture.start)] {
            let route = try #require(planner.route(from: start, to: target))
            let transition = try #require(transitions(route).first)
            #expect(transitions(route).map(\.kind) == [.ramp])
            #expect(transition.slopeDegrees == 4.37)
            #expect(transition.from.zoneID == start.zoneID)
            #expect(transition.to.zoneID == target.zoneID)
            #expect(abs(transition.rampLength - sqrt(14.4 * 14.4 + 1.1 * 1.1)) < 0.001)
            #expect(abs(route.walkingLength - surfaces(route).reduce(0, { $0 + $1.route.length }) - transition.rampLength) < 0.001)
            #expect(surfaces(route).allSatisfy { surface in surface.points.allSatisfy { $0.y == surface.elevation } })
        }
    }

    @Test func rampEligibilityRequiresMeasuredSlopeAndStepFreeLimits() throws {
        for variant in 0..<4 {
            var fixture = rampFixture()
            switch variant {
            case 0: fixture.map.connectors[0].slopeDegrees = nil
            case 1: fixture.map.connectors[0].slopeDegrees = 10
            case 2: fixture.map.connectors[0].stepFree = nil
            default: fixture.map.connectors[0].minimumClearWidthMeters = 0.8
            }
            let planner = try ElevatedFloorRoutePlanner(map: fixture.map)
            #expect(planner.route(from: fixture.start, to: fixture.target) == nil)
            let fastest = planner.route(from: fixture.start, to: fixture.target, conditions: RoutePreference.fastest.conditions())
            #expect((fastest != nil) == (variant != 0))
        }
        var fixture = rampFixture()
        fixture.map.connectors[0].slopeDegrees = .nan
        #expect(throws: (any Error).self) { try ElevatedFloorRoutePlanner(map: fixture.map) }
    }

    @Test func rampMetadataCannotDisguiseAVerticalOrSteeperSpan() {
        var vertical = rampFixture()
        vertical.map.connectors[0].to.position = [-7.2, 1.1, 0]
        #expect(throws: (any Error).self) { try ElevatedFloorRoutePlanner(map: vertical.map) }
        var understated = rampFixture()
        understated.map.connectors[0].slopeDegrees = 1
        #expect(throws: (any Error).self) { try ElevatedFloorRoutePlanner(map: understated.map) }
    }

    private func fixture() -> (map: ElevatedFloorMap, start: ElevatedFloorLocation, destination: AccessPoint) {
        let destination = AccessPoint(kind: .destination, name: "Auditorium", position: [3, 1.4, 0], source: .manual, confidence: 1)
        let lower = zone("lower", elevation: 0)
        var raised = zone("raised", elevation: 1.4, points: [destination])
        raised.name = "Auditorium landing"
        let stairs = ElevatedFloorConnector(id: "steps", kind: .stairs,
            from: .init(zoneID: "lower", position: [-1, 0, 0]), to: .init(zoneID: "raised", position: [1, 1.4, 0]),
            availability: .available, stepFree: false, minimumClearWidthMeters: 1.2, estimatedSeconds: 3)
        let elevator = ElevatedFloorConnector(id: "lift", name: "Auditorium elevator", kind: .elevator,
            from: .init(zoneID: "lower", position: [-4, 0, 3]), to: .init(zoneID: "raised", position: [-4, 1.4, 3]),
            availability: .available, stepFree: true, minimumClearWidthMeters: 1.1, estimatedSeconds: 20)
        return (.init(displayFloor: 1, zones: [lower, raised], connectors: [stairs, elevator]),
                .init(zoneID: "lower", position: [-3, 0, 0]), destination)
    }

    private func zone(_ id: String, elevation: Float, points: [AccessPoint] = []) -> ElevatedFloorZone {
        ElevatedFloorZone(id: id, map: VenueMap(floorY: elevation,
            footprints: [Footprint(kind: .floor, center: [0, 0], size: [10, 10], yaw: 0, bottom: elevation)],
            points: points, requiresMeasuredFloorCoverage: true))
    }

    private func rampFixture() -> (map: ElevatedFloorMap, start: ElevatedFloorLocation, target: ElevatedFloorLocation) {
        var lower = zone("lower", elevation: 0)
        var upper = zone("food-court", elevation: 1.1)
        lower.map.footprints[0].size = [20, 6]
        upper.map.footprints[0].size = [20, 6]
        let ramp = ElevatedFloorConnector(id: "food-court-corridor", name: "Food court corridor", kind: .ramp,
            from: .init(zoneID: "lower", position: [-7.2, 0, 0]),
            to: .init(zoneID: "food-court", position: [7.2, 1.1, 0]), availability: .available,
            stepFree: true, minimumClearWidthMeters: 2.8, slopeDegrees: 4.37, estimatedSeconds: 14.45)
        return (.init(displayFloor: 1, zones: [lower, upper], connectors: [ramp]),
                .init(zoneID: "lower", position: [-8, 0, 0]), .init(zoneID: "food-court", position: [8, 1.1, 0]))
    }

    private func transitions(_ route: ElevatedFloorRoute) -> [ElevatedFloorTransition] {
        route.segments.compactMap { if case .transition(let transition) = $0 { return transition }; return nil }
    }

    private func surfaces(_ route: ElevatedFloorRoute) -> [ElevatedFloorSurfaceRoute] {
        route.segments.compactMap { if case .surface(let surface) = $0 { return surface }; return nil }
    }
}
