import AccessCore
import XCTest
import simd
@testable import InView

final class FloorRoutePreviewTests: XCTestCase {
    func testArrivalWalkUsesItsOwnFloorAndChosenElevator() throws {
        let map = try XCTUnwrap(StudentCenterCatalog.map())
        let destination = try XCTUnwrap(FloorNavigationCatalog.destinations(level: 2,
            map: map, includesModel: true).first { $0.point.title == "Lounge" })
        let preview = FloorArrivalPreview(destination: destination,
            floor: FloorPreviewMap(level: 2, map: map), preference: .stepFree)
        XCTAssertNil(preview.route, "Names do not establish which elevator connects two floors")
        XCTAssertEqual(preview.landings.count, 2)
        for landing in preview.landings {
            let selected = preview.selecting(landing, preference: .stepFree)
            let route = try XCTUnwrap(selected.route)
            XCTAssertEqual(route.destination, destination.point)
            XCTAssertLessThan(simd_distance(try XCTUnwrap(route.waypoints.first), landing.point.floorPoint), 1,
                "The planner may move the start to a nearby clear cell at the chosen elevator")
            XCTAssertNil(selected.elevatedRoute)
            XCTAssertEqual(selected.floor.level, 2)
        }
        XCTAssertNil(preview.landing, "Choosing a landing creates a new preview without mutating another floor's state")
    }

    func testArrivalWalkOnFloorOneUsesMeasuredElevationZones() throws {
        let map = try XCTUnwrap(StudentCenterFloor1Catalog.elevatedMap())
        let destination = try XCTUnwrap(FloorNavigationCatalog.destinations(level: 1,
            map: StudentCenterFloor1Catalog.displayMap(), includesModel: true).first { $0.point.title == "Auditorium" })
        let preview = FloorArrivalPreview(destination: destination,
            floor: FloorPreviewMap(level: 1, map: StudentCenterFloor1Catalog.displayMap(), elevatedMap: map),
            preference: .stepFree)
        XCTAssertFalse(preview.landings.isEmpty)
        XCTAssertTrue(preview.landings.allSatisfy { $0.kind == .elevator })
        let landing = try XCTUnwrap(preview.landings.first { $0.elevatedLocation?.zoneID == "main" })
        let selected = preview.selecting(landing, preference: .stepFree)
        XCTAssertNil(selected.route, "The flattened drawing map must never be used for Floor 1 walking routes")
        let route = try XCTUnwrap(selected.elevatedRoute)
        XCTAssertEqual(route.destination.id, destination.point.id)
        XCTAssertEqual(route.destinationZoneID, map.destinationZones[destination.point.id])
    }

    func testUnmappedAndMismatchedFloorsCannotBorrowWalkingCoverage() throws {
        let map = try XCTUnwrap(StudentCenterCatalog.map())
        let destination = try XCTUnwrap(FloorNavigationCatalog.destinations(level: 3,
            map: nil, includesModel: true).first { $0.point.title == "Window lounge" })
        let unmapped = FloorArrivalPreview(destination: destination,
            floor: FloorPreviewMap(level: 3, map: nil), preference: .fastest)
        XCTAssertTrue(unmapped.landings.isEmpty)
        XCTAssertNil(unmapped.route)
        var wrongFloorDestination = destination
        wrongFloorDestination.isRoutable = true
        let mismatched = FloorArrivalPreview(destination: wrongFloorDestination,
            floor: FloorPreviewMap(level: 2, map: map), preference: .stepFree)
        let selected = mismatched.selecting(try XCTUnwrap(mismatched.landings.first), preference: .stepFree)
        XCTAssertNil(selected.route)
        XCTAssertNil(selected.elevatedRoute)
    }

    func testStepFreePreferenceRemovesStairLandingsAndRejectsOldSelection() throws {
        let map = try XCTUnwrap(StudentCenterFloor1Catalog.elevatedMap())
        let destination = try XCTUnwrap(FloorNavigationCatalog.destinations(level: 1,
            map: StudentCenterFloor1Catalog.displayMap()).first { $0.point.title == "Auditorium" })
        let floor = FloorPreviewMap(level: 1, map: StudentCenterFloor1Catalog.displayMap(), elevatedMap: map)
        let fastest = FloorArrivalPreview(destination: destination, floor: floor, preference: .fastest)
        let stairs = try XCTUnwrap(fastest.landings.first { $0.kind == .stairs })
        let stepFree = FloorArrivalPreview(destination: destination, floor: floor, preference: .stepFree)
        XCTAssertTrue(stepFree.landings.allSatisfy { $0.kind == .elevator })
        XCTAssertNil(stepFree.selecting(stairs, preference: .stepFree).route)
        XCTAssertNil(stepFree.selecting(stairs, preference: .stepFree).elevatedRoute)
        XCTAssertNil(fastest.selecting(stairs, preference: .stepFree).elevatedRoute)
    }

    func testDepartureWalkRoutesFromTheRoomToTheSelectedElevatedLanding() throws {
        let map = try XCTUnwrap(StudentCenterFloor1Catalog.elevatedMap())
        let room = try XCTUnwrap(StudentCenterFloor1Catalog.displayMap()?.points.first { $0.title == "Auditorium" })
        let start = ElevatedFloorLocation(zoneID: try XCTUnwrap(map.destinationZones[room.id]), position: room.position)
        let floor = FloorPreviewMap(level: 1, map: nil, elevatedMap: map)
        let landing = try XCTUnwrap(FloorArrivalPreview.landings(in: floor, preference: .stepFree)
            .first { $0.elevatedLocation?.zoneID == "main" })
        let route = try XCTUnwrap(FloorArrivalPreview.departureRoute(from: start, to: landing,
            in: map, preference: .stepFree))
        XCTAssertEqual(route.destination.position, landing.point.position)
        XCTAssertEqual(route.destinationZoneID, landing.elevatedLocation?.zoneID)
        XCTAssertEqual(route.preference, .stepFree)
    }

    func testInvalidElevatedMapNeverFallsBackToItsFlattenedDrawingMap() throws {
        var map = try XCTUnwrap(StudentCenterFloor1Catalog.elevatedMap())
        let drawing = try XCTUnwrap(StudentCenterFloor1Catalog.displayMap())
        let destination = try XCTUnwrap(FloorNavigationCatalog.destinations(level: 1, map: drawing)
            .first { $0.point.title == "Auditorium" })
        map.zones = []
        let preview = FloorArrivalPreview(destination: destination,
            floor: FloorPreviewMap(level: 1, map: drawing, elevatedMap: map), preference: .stepFree)
        let landing = try XCTUnwrap(preview.landings.first)
        let selected = preview.selecting(landing, preference: .stepFree)
        XCTAssertNil(selected.route)
        XCTAssertNil(selected.elevatedRoute)
    }
}
