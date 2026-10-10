import AccessCore
import Foundation
import Testing

@Test func newScanWithNoMeasuredFloorDoesNotRouteThroughUnknownSpace() throws {
    let elevator = AccessPoint(kind: .elevator, position: [6, 0, 6], source: .manual, confidence: 1)
    let map = VenueMap(floorY: 0, footprints: [], points: [elevator], requiresMeasuredFloorCoverage: true)
    let grid = OccupancyGrid(map: map, clearance: 0.4)
    #expect(grid.nearestFreeIndex(to: .zero, within: 1.5) == nil)
    #expect(grid.nearestFreeIndex(to: elevator.floorPoint, within: 1.5) == nil)
    let decoded = try JSONDecoder().decode(VenueMap.self, from: JSONEncoder().encode(map))
    #expect(decoded.requiresMeasuredFloorCoverage == true)
}

@Test func legacyFloorlessMapDecodesWithoutRequiringNewCoverageField() throws {
    let encoded = Data(#"{"createdAt":0,"floorY":0,"footprints":[],"points":[]}"#.utf8)
    let map = try JSONDecoder().decode(VenueMap.self, from: encoded)
    #expect(map.requiresMeasuredFloorCoverage == nil)
    #expect(OccupancyGrid(map: map, clearance: 0.4).nearestFreeIndex(to: .zero, within: 1.5) != nil)
}
