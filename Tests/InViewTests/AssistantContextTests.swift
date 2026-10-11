import AccessCore
import XCTest
@testable import InView

final class AssistantContextTests: XCTestCase {
    private func catalogContext() throws -> GeminiAssistantClient.Context {
        let map = try XCTUnwrap(StudentCenterCatalog.map())
        return GeminiAssistantClient.Context(buildingName: StudentCenterCatalog.buildingName, currentFloor: 2, floors: [
            .init(level: 1, summary: "no map yet", points: [], landmarks: []),
            .init(level: 2, summary: "3D model and partial floor scan", points: map.points,
                  landmarks: StudentCenterCatalog.modelLandmarks(for: 2)),
            .init(level: 3, summary: "3D model", points: [], landmarks: StudentCenterCatalog.modelLandmarks(for: 3)),
        ])
    }

    func testMeasuredElevatorsReplaceModelLiftsOnTheirFloor() throws {
        let context = try catalogContext()
        let floor2 = context.places.filter { $0.floor == 2 }
        XCTAssertFalse(floor2.contains { $0.name == "Lifts" })
        XCTAssertEqual(floor2.filter { $0.kind == "elevator" }.count, 2)
        XCTAssertTrue(context.places.contains { $0.floor == 3 && $0.name == "Lifts" })
    }

    func testLandmarksNameTheirNearestNeighboursOnTheSameFloor() throws {
        let context = try catalogContext()
        let landmark = try XCTUnwrap(context.places.first { $0.floor == 2 && $0.kind == "place" })
        XCTAssertEqual(landmark.nearby.count, 2)
        XCTAssertFalse(landmark.nearby.contains(landmark.name))
        let floor2Names = Set(StudentCenterCatalog.modelLandmarks(for: 2).map(\.title))
        XCTAssertTrue(Set(landmark.nearby).isSubset(of: floor2Names))
    }

    func testDistancesFromThePersonOnlyCoverTheirOwnFloor() throws {
        let map = try XCTUnwrap(StudentCenterCatalog.map())
        let elevator = try XCTUnwrap(map.points.first { $0.kind == .elevator })
        let user = elevator.floorPoint + SIMD2(3, 4)
        let context = GeminiAssistantClient.Context(buildingName: "Test", currentFloor: 2, floors: [
            .init(level: 2, summary: "floor scan", points: map.points, landmarks: []),
            .init(level: 3, summary: "3D model", points: [], landmarks: StudentCenterCatalog.modelLandmarks(for: 3)),
        ], user: (floor: 2, position: user))
        let measured = try XCTUnwrap(context.places.first { $0.id == elevator.id })
        XCTAssertEqual(try XCTUnwrap(measured.distance), 5, accuracy: 0.001)
        XCTAssertTrue(context.places.filter { $0.floor == 3 }.allSatisfy { $0.distance == nil })
        XCTAssertTrue(GeminiAssistantClient.instructions(for: context).contains("about 5 m from the person"))
    }

    func testInstructionsListEveryPlaceAndFloor() throws {
        let context = try catalogContext()
        let prompt = GeminiAssistantClient.instructions(for: context)
        for place in context.places { XCTAssertTrue(prompt.contains(place.id.uuidString)) }
        XCTAssertTrue(prompt.contains("Floor 1: no map yet"))
        XCTAssertTrue(prompt.contains("looking at Floor 2"))
        print(prompt)
    }
}
