import Foundation
import simd
import Testing
@testable import AccessCore

private let radius = 6_378_137.0
private let radians = Double.pi / 180

/// Measures geographic offsets independently in the renderers' projected space.
private func geographicMeters(from origin: BuildingMapReference, to point: GeographicCoordinate) -> SIMD2<Double> {
    let scale = cos(origin.latitude * radians)
    var longitudeDelta = point.longitude - origin.longitude
    if longitudeDelta > 180 { longitudeDelta -= 360 }
    if longitudeDelta < -180 { longitudeDelta += 360 }
    let east = longitudeDelta * radians * radius * scale
    let north = radius * log(tan(.pi / 4 + point.latitude * radians / 2)
                            / tan(.pi / 4 + origin.latitude * radians / 2)) * scale
    return [east, north]
}

@Test func geographicOriginRetainsItsLocation() throws {
    let reference = BuildingMapReference(latitude: 37.3324, longitude: -122.0048)
    try reference.validate()
    let origin = try reference.coordinate(for: .zero)
    #expect(abs(origin.latitude - reference.latitude) < 1e-10)
    #expect(abs(origin.longitude - reference.longitude) < 1e-10)
    #expect(reference.headingDegrees == 0)
    #expect(reference.horizontalAccuracyM == nil)
}

@Test func geographicHeadingUsesLocalNegativeZAsNorth() throws {
    let northFacing = BuildingMapReference(latitude: 0, longitude: 0)
    let north = try geographicMeters(from: northFacing, to: northFacing.coordinate(for: [0, -10]))
    let east = try geographicMeters(from: northFacing, to: northFacing.coordinate(for: [10, 0]))
    #expect(simd_distance(north, [0, 10]) < 1e-7)
    #expect(simd_distance(east, [10, 0]) < 1e-7)

    let eastFacing = BuildingMapReference(latitude: 0, longitude: 0, headingDegrees: 90)
    let forward = try geographicMeters(from: eastFacing, to: eastFacing.coordinate(for: [0, -10]))
    let right = try geographicMeters(from: eastFacing, to: eastFacing.coordinate(for: [10, 0]))
    #expect(simd_distance(forward, [10, 0]) < 1e-7)
    #expect(simd_distance(right, [0, -10]) < 1e-7)
}

@Test func geographicProjectionPreservesMetersAtDifferentLatitudes() throws {
    for latitude in [0.0, 37.3, 60.0, -60.0] {
        let reference = BuildingMapReference(latitude: latitude, longitude: 12)
        let coordinate = try reference.coordinate(for: [30, -40])
        let meters = geographicMeters(from: reference, to: coordinate)
        #expect(simd_distance(meters, [30, 40]) < 1e-6)
        // A 30 m eastward offset spans twice as much longitude at 60 degrees as at the equator.
        let expectedLongitudeDelta = 30 / (radius * cos(latitude * radians)) / radians
        #expect(abs(coordinate.longitude - reference.longitude - expectedLongitudeDelta) < 1e-10)
    }
}

@Test func geographicCoordinatesRoundTripWithoutChangingTheLocalFrame() throws {
    for heading in [0.0, 90, -45, 360, 725.5] {
        let reference = BuildingMapReference(latitude: 51.5, longitude: -0.1, headingDegrees: heading)
        for point: SIMD2<Float> in [[0, 0], [31.2, -19.7], [-102.8, 210.6]] {
            let result = try reference.mapPoint(for: reference.coordinate(for: point))
            #expect(simd_distance(result, point) < 0.0001)
        }
    }
}

@Test func geographicProjectionCrossesTheDatelineLocally() throws {
    for longitude in [179.99999, -179.99999] {
        let reference = BuildingMapReference(latitude: 25, longitude: longitude)
        let point = SIMD2<Float>(longitude > 0 ? 20 : -20, -3)
        let coordinate = try reference.coordinate(for: point)
        #expect(coordinate.longitude * longitude < 0)
        #expect(abs(coordinate.longitude) < 180)
        #expect(simd_distance(try reference.mapPoint(for: coordinate), point) < 0.0001)
    }
}

@Test func geographicProjectionRejectsInvalidAndOutOfCoverageValues() throws {
    let invalidReferences = [
        BuildingMapReference(latitude: .nan, longitude: 0),
        BuildingMapReference(latitude: 85.05112878, longitude: 0),
        BuildingMapReference(latitude: -90, longitude: 0),
        BuildingMapReference(latitude: 0, longitude: .infinity),
        BuildingMapReference(latitude: 0, longitude: 181),
        BuildingMapReference(latitude: 0, longitude: 0, headingDegrees: .nan),
        BuildingMapReference(latitude: 0, longitude: 0, horizontalAccuracyM: -1),
        BuildingMapReference(latitude: 0, longitude: 0, horizontalAccuracyM: .infinity),
    ]
    for reference in invalidReferences {
        #expect(throws: BuildingMapReferenceError.self) { try reference.validate() }
    }
    let reference = BuildingMapReference(latitude: 0, longitude: 0)
    #expect(throws: BuildingMapReferenceError.invalidMapPoint) { try reference.coordinate(for: [.nan, 0]) }
    #expect(throws: BuildingMapReferenceError.outsideMapCoverage) { try reference.coordinate(for: [0, -.greatestFiniteMagnitude]) }
    #expect(throws: BuildingMapReferenceError.invalidLatitude) {
        try reference.mapPoint(for: GeographicCoordinate(latitude: 90, longitude: 0))
    }
    let nearPole = BuildingMapReference(latitude: 85.05, longitude: 0)
    #expect(throws: BuildingMapReferenceError.outsideMapCoverage) { try nearPole.coordinate(for: [0, -1_000]) }
}

@Test func oldVenueMapJSONNeedsNoGeographicReference() throws {
    let oldJSON = Data("""
    {"createdAt":0,"floorY":-1.3,"footprints":[],"points":[]}
    """.utf8)
    let map = try JSONDecoder().decode(VenueMap.self, from: oldJSON)
    #expect(map.geographicReference == nil)
    #expect(map.floorY == -1.3)

    var placed = map
    placed.geographicReference = BuildingMapReference(latitude: 33.75, longitude: -84.39, headingDegrees: 31, horizontalAccuracyM: 8)
    let restored = try JSONDecoder().decode(VenueMap.self, from: JSONEncoder().encode(placed))
    #expect(restored.geographicReference == placed.geographicReference)
    #expect(restored.floorY == map.floorY)
    #expect(restored.footprints == map.footprints)
}

@Test func geographicPlacementDoesNotChangeIndoorRouting() throws {
    let destination = AccessPoint(kind: .destination, name: "Lobby", position: [3, 0, 0], source: .manual, confidence: 1)
    let walls = [
        Footprint(kind: .wall, center: [0, -3], size: [8, 0.15], yaw: 0),
        Footprint(kind: .wall, center: [0, 3], size: [8, 0.15], yaw: 0),
        Footprint(kind: .wall, center: [-4, 0], size: [6, 0.15], yaw: .pi / 2),
        Footprint(kind: .wall, center: [4, 0], size: [6, 0.15], yaw: .pi / 2),
    ]
    let map = VenueMap(floorY: 0, footprints: walls, points: [destination])
    let indoorRoute = try #require(RoutePlanner(map: map).route(from: [-3, 0], to: destination))
    var placed = map
    // Even an unusable placement must not prevent local routing.
    placed.geographicReference = BuildingMapReference(latitude: 90, longitude: 0)
    let placedRoute = try #require(RoutePlanner(map: placed).route(from: [-3, 0], to: destination))
    #expect(placedRoute.waypoints == indoorRoute.waypoints)
    #expect(placedRoute.destination.id == destination.id)
    #expect(placedRoute.length == indoorRoute.length)
}
