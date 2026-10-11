import AccessCore
import XCTest
@testable import InView

final class StudentCenterFloor1CatalogTests: XCTestCase {
    func testBundledFloorOneKeepsRaisedAreasOnOneFloorAndRoutesByPreference() throws {
        let map = try StudentCenterFloor1Catalog.mapResult().get()
        XCTAssertEqual(map.displayFloor, 1)
        XCTAssertEqual(Set(map.zones.map(\.map.floorY)), [0, 1.10, 1.58])
        let points = map.zones.flatMap { $0.map.points }
        let information = try XCTUnwrap(points.first { $0.title == "Information" })
        let auditorium = try XCTUnwrap(points.first { $0.title == "Auditorium" })
        let start = ElevatedFloorLocation(zoneID: try XCTUnwrap(map.destinationZones[information.id]),
                                          position: information.position)
        let planner = try ElevatedFloorRoutePlanner(map: map)
        for preference: RoutePreference in [.stepFree, .fastest] {
            let route = try XCTUnwrap(planner.route(from: start, to: auditorium.id, conditions: preference.conditions()))
            let transitions = route.segments.compactMap { segment -> ElevatedFloorConnectorKind? in
                if case .transition(let transition) = segment { return transition.kind }
                return nil
            }
            XCTAssertEqual(transitions, preference == .stepFree ? [.elevator] : [.stairs])
        }
        XCTAssertNotNil(StudentCenterFloor1Catalog.modelURL())
        XCTAssertNotNil(StudentCenterFloor1Catalog.previewURL())
    }

    private func map() -> ElevatedFloorMap {
        let destination = AccessPoint(kind: .destination, name: "Auditorium", position: [3, 1.2, 3], source: .manual, confidence: 1)
        let lower = Footprint(floor: [[-5, -5], [5, -5], [5, 5], [-5, 5]], bottom: 0)
        let raised = Footprint(floor: [[1, 1], [5, 1], [5, 5], [1, 5]], bottom: 1.2)
        return ElevatedFloorMap(displayFloor: 1, zones: [
            ElevatedFloorZone(id: "main", map: VenueMap(floorY: 0, footprints: [lower], points: [])),
            ElevatedFloorZone(id: "auditorium", map: VenueMap(floorY: 1.2, footprints: [raised], points: [destination]))
        ], connectors: [])
    }

    func testNavigationDecodeAndDisplayMapPreserveRaisedZoneAndDestinationID() throws {
        let original = map()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try StudentCenterFloor1Catalog.decodeNavigation(encoder.encode(original))
        let display = try XCTUnwrap(StudentCenterFloor1Catalog.makeDisplayMap(from: decoded))
        XCTAssertEqual(decoded.displayFloor, 1)
        XCTAssertEqual(display.footprints.compactMap(\.bottom), [0, 1.2])
        XCTAssertEqual(display.points.first?.id, original.zones[1].map.points.first?.id)
        XCTAssertEqual(display.points.first?.position.y, 1.2)
        XCTAssertEqual(display.requiresMeasuredFloorCoverage, true)
    }

    func testRepeatedVisualLabelKeepsMeasuredIDAndPosition() throws {
        let data = Data(#"{"floor_elevations_m":{"1":0},"labels":[{"floor":1,"title":"Auditorium","position":[4,0,4]},{"floor":1,"title":"Elevator lobby","position":[0,0,0]}]}"#.utf8)
        let layout = try XCTUnwrap(StudentCenterFloor1Catalog.decodeLayout(data))
        let map = map()
        let landmarks = StudentCenterFloor1Catalog.landmarks(map: map, layout: layout)
        XCTAssertEqual(landmarks.count, 2)
        let measured = try XCTUnwrap(landmarks.first { $0.title == "Auditorium" })
        XCTAssertEqual(measured.id, map.zones[1].map.points[0].id)
        XCTAssertEqual(measured.position, map.zones[1].map.points[0].position)
        XCTAssertEqual(landmarks.map(\.id), StudentCenterFloor1Catalog.landmarks(map: map, layout: layout).map(\.id))
    }

    func testInvalidAndWrongFloorResourcesFailClosed() throws {
        XCTAssertThrowsError(try StudentCenterFloor1Catalog.decodeNavigation(Data("{}".utf8)))
        var wrongFloor = map()
        wrongFloor.displayFloor = 2
        XCTAssertNil(StudentCenterFloor1Catalog.makeDisplayMap(from: wrongFloor))
        XCTAssertNil(StudentCenterFloor1Catalog.decodeLayout(Data(#"{"floor_elevations_m":{"1":0},"labels":[{"floor":2,"title":"Auditorium","position":[0,0,0]}]}"#.utf8)))
        XCTAssertNil(StudentCenterFloor1Catalog.decodeLayout(Data(#"{"floor_elevations_m":{"1":0},"labels":[{"floor":1,"title":"Auditorium","position":[0,0]}]}"#.utf8)))
    }
}
