import Foundation
import simd
import Testing
@testable import AccessCore

/// A door in a wall along x at z = 0, its normal along z.
private let door = Footprint(kind: .door, center: [2, 0], size: [1.0, 0.15], yaw: 0)

@Test func placingAddsANewPlaceAndReplacesAnEditedOneInOrder() {
    var map = VenueMap(floorY: -1.3, footprints: [door], points: [point(.ramp, 5, 5)])
    var lounge = point(.destination, 1, 3)
    lounge.name = "Lounge"
    map.place(lounge)
    #expect(map.points.map(\.title) == ["Ramp", "Lounge"])
    lounge.name = "Quiet lounge"
    lounge.requiresAssistance = true
    map.place(lounge)
    #expect(map.points.count == 2)
    #expect(map.points[1].title == "Quiet lounge")
    #expect(map.points[1].requiresAssistance)
    #expect(map.points[1].floorPoint == lounge.floorPoint)
}

@Test func placingAnElevatorMovesItInFrontOfItsDoorOnce() throws {
    var map = VenueMap(floorY: -1.3, footprints: [door], points: [])
    var elevator = point(.elevator, 2.3, 0.9)
    map.place(elevator)
    let placed = try #require(map.points.first)
    #expect(simd_distance(placed.floorPoint, [2, 0.6]) < 1e-4)
    // Renaming keeps where it was snapped; it doesn't snap again from the edited copy.
    elevator = placed
    elevator.name = "East elevator"
    map.place(elevator)
    #expect(map.points.first?.floorPoint == placed.floorPoint)
    #expect(map.points.first?.title == "East elevator")
}

@Test func changingAPlaceIntoAnElevatorSnapsIt() throws {
    var map = VenueMap(floorY: 0, footprints: [door], points: [])
    var place = point(.destination, 1.8, -0.4)
    map.place(place)
    #expect(map.points.first?.floorPoint == place.floorPoint)
    place.kind = .elevator
    map.place(place)
    let snapped = try #require(map.points.first)
    #expect(simd_distance(snapped.floorPoint, [2, -0.6]) < 1e-4)
}

@Test func removingAPlaceLeavesTheOthers() {
    let keep = point(.elevator, 9, 9)
    let drop = point(.destination, 1, 1)
    var map = VenueMap(floorY: 0, footprints: [], points: [keep, drop])
    map.removePoint(id: drop.id)
    #expect(map.points == [keep])
    map.removePoint(id: UUID())
    #expect(map.points == [keep])
}
