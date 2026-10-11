import AccessCore
import XCTest
@testable import InView

final class FloorNavigationCatalogTests: XCTestCase {
    func testDestinationsIncludeEveryBundledFloorWithoutPromotingUnmappedLandmarks() throws {
        let first = FloorNavigationCatalog.destinations(level: 1,
            map: try XCTUnwrap(StudentCenterFloor1Catalog.displayMap()), includesModel: true)
        let second = FloorNavigationCatalog.destinations(level: 2,
            map: try XCTUnwrap(StudentCenterCatalog.map()), includesModel: true)
        let third = FloorNavigationCatalog.destinations(level: 3, map: nil, includesModel: true)
        XCTAssertTrue(first.contains { $0.point.title == "Auditorium" && $0.isRoutable })
        XCTAssertTrue(second.contains { $0.point.title == "Lounge" && $0.isRoutable })
        XCTAssertTrue(third.contains { $0.point.title == "Window lounge" })
        XCTAssertTrue(third.allSatisfy { !$0.isRoutable })
        let all = first + second + third
        XCTAssertEqual(Set(all.map(\.level)), [1, 2, 3])
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertFalse(second.contains { $0.point.title == "Lifts" }, "Measured elevators replace the repeated model label")
    }

    func testSavedFloorDestinationKeepsItsFloorIdentityAndCustomName() {
        let point = AccessPoint(kind: .destination, name: "Office", position: [2, 0, 3], source: .manual, confidence: 1)
        let identity = ScanFloorIdentity(level: 7, name: "Seventh floor")
        let floor = SavedFloor(identity: identity, storageID: UUID(), savedAt: .now, captureID: nil)
        let map = VenueMap(floorY: 0, footprints: [], points: [point])
        let destinations = FloorNavigationCatalog.destinations(level: floor.level, name: floor.name, map: map, savedFloor: floor)
        XCTAssertEqual(destinations.count, 1)
        XCTAssertEqual(destinations.first?.savedFloor?.id, floor.id)
        XCTAssertEqual(destinations.first?.point.id, point.id)
        XCTAssertEqual(destinations.first?.title, "Office · Seventh floor")
    }

    func testEndpointMenusIncludeUnmappedFloorsAndKeepRepeatedPlaceIDsSeparate() {
        let point = AccessPoint(kind: .destination, name: "Lounge", position: [0, 0, 0], source: .manual, confidence: 1)
        let destinations = [
            FloorNavigationDestination(level: 3, floorName: "Floor 3", point: point, isRoutable: false),
            FloorNavigationDestination(level: 1, floorName: "Floor 1", point: point),
            FloorNavigationDestination(level: 2, floorName: "Floor 2", point: point)
        ]
        let floors = FloorNavigationCatalog.sections(for: destinations)
        XCTAssertEqual(floors.map(\.level), [1, 2, 3])
        XCTAssertEqual(floors.map(\.name), ["Floor 1", "Floor 2", "Floor 3"])
        XCTAssertEqual(floors.flatMap(\.places).count, 3)
        XCTAssertEqual(Set(floors.flatMap(\.places).map(\.id)).count, 3)
        XCTAssertEqual(floors.last?.places.first?.isRoutable, false,
            "A lack of walking coverage must not remove a floor from either endpoint menu")
    }

    func testChangingAndSwappingStartKeepsTheDestinationOnItsOwnFloor() {
        let start = FloorNavigationDestination(level: 1, floorName: "Floor 1",
            point: AccessPoint(kind: .destination, name: "Auditorium", position: [1, 0, 2], source: .manual, confidence: 1))
        let destination = FloorNavigationDestination(level: 2, floorName: "Floor 2",
            point: AccessPoint(kind: .destination, name: "Lounge", position: [3, 0, 4], source: .manual, confidence: 1))
        let selection = FloorNavigationSelection(start: start, destination: destination)
        XCTAssertEqual(selection.destination?.title, "Lounge · Floor 2")
        XCTAssertEqual(selection.swapped.start, destination)
        XCTAssertEqual(selection.swapped.destination, start)
        XCTAssertEqual(selection.swapped.swapped, selection)
        XCTAssertEqual(FloorNavigationSelection(destination: destination).destination, destination,
            "A floor arrival can clear the old start while retaining the final destination")
    }
}
