import AccessCore
import Foundation
import simd

/// A synthetic navigation session built from the same measured capture as the room demo.
/// It never reads or changes the user's saved map or capture selection.
enum NavigationDemo {
    struct Snapshot {
        let scene: ProcessedScene
        let map: VenueMap
        let startPosition: SIMD2<Float>
        let route: Route?
        let failureReason: String?
    }

    static var startPosition: SIMD2<Float> {
        (try? loaded.get().startPosition) ?? SIMD2(-1.825, 0.275)
    }

    /// Radians clockwise from -z: zero faces -z, and pi / 2 faces +x.
    static var heading: Float {
        guard let route, route.waypoints.count >= 2 else { return 0 }
        let direction = route.waypoints[1] - route.waypoints[0]
        return atan2(direction.x, -direction.y)
    }

    static var scene: ProcessedScene? { try? loaded.get().scene }
    /// An explicitly synthetic upper level for comparing floor cutaways. It
    /// contains only the reception room; its remaining wing is intentionally unmapped.
    static var comparisonScene: ProcessedScene? {
        guard var result = scene else { return nil }
        let elevation: Float = 3.4
        var upperSurfaces = result.surfaces.filter { !$0.sourceID.hasPrefix("hallway-") && !$0.sourceID.hasPrefix("meeting-") }
        for index in upperSurfaces.indices {
            upperSurfaces[index].sourceID = "demo-upper-" + upperSurfaces[index].sourceID
            upperSurfaces[index].mapFromSurface[13] += elevation
        }
        var upperObjects = result.objects.filter { $0.mapFromObject.count == 16 && $0.mapFromObject[14] > -2.5 }
        for index in upperObjects.indices {
            upperObjects[index].sourceID = "demo-upper-" + upperObjects[index].sourceID
            upperObjects[index].mapFromObject[13] += elevation
            upperObjects[index].obstacleBounds.min[1] += elevation
            upperObjects[index].obstacleBounds.max[1] += elevation
            for corner in upperObjects[index].obstacleCorners.indices {
                upperObjects[index].obstacleCorners[corner][1] += elevation
            }
        }
        result.surfaces += upperSurfaces
        result.objects += upperObjects
        return result
    }
    static var map: VenueMap? { try? loaded.get().map }
    static var route: Route? { try? loaded.get().route }
    static var failureReason: String? {
        switch loaded {
        case .success(let snapshot): return snapshot.failureReason
        case .failure(let error): return error.localizedDescription
        }
    }

    private static let loaded: Result<Snapshot, Error> = Result {
        guard let sceneURL = Bundle.main.url(forResource: "demo-room-scene", withExtension: "json"),
              let captureURL = Bundle.main.url(forResource: "demo-room-capture", withExtension: "json") else {
            throw CaptureValidationError.invalid("The navigation demo could not be loaded.")
        }
        return try load(sceneURL: sceneURL, captureURL: captureURL)
    }

    /// Also used to verify this fixture with the real planner outside the iPhone app.
    static func load(sceneURL: URL, captureURL: URL) throws -> Snapshot {
        let capture = try JSONDecoder().decode(CaptureBundle.self, from: Data(contentsOf: captureURL))
        let scene = try JSONDecoder().decode(ProcessedScene.self, from: Data(contentsOf: sceneURL))
        try scene.validate(source: capture)
        guard let metadataValue = capture.metadata else {
            throw CaptureValidationError.invalid("The navigation demo has no destinations.")
        }
        let metadata = try JSONDecoder().decode(
            Metadata.self, from: JSONEncoder().encode(metadataValue)
        )
        let start = try position(metadata.startPosition)
        let startPosition = SIMD2(start.x, start.z)

        let floorHeights = capture.surfaces.filter { $0.kind == "floor" }
            .map { $0.mapFromSurface[13] }.sorted()
        let floorY = floorHeights.isEmpty ? Float(0) : floorHeights[floorHeights.count / 2]
        let wallThickness: Float = 0.15
        var footprints: [Footprint] = []
        for surface in capture.surfaces {
            let kind: Footprint.Kind
            switch surface.kind {
            case "wall": kind = .wall
            case "door": kind = .door
            case "opening": kind = .opening
            default: continue
            }
            footprints.append(Footprint(kind: kind, transform: matrix(surface.mapFromSurface),
                                        width: surface.dimensionsM[0], depth: wallThickness))
        }
        for object in capture.objects {
            // The synthetic rug is decoration; every other floor-level measured box blocks travel.
            guard object.category != "rug",
                  object.mapFromObject[13] - object.dimensionsM[1] / 2 < floorY + 0.7 else { continue }
            footprints.append(Footprint(kind: object.category == "stairs" ? .stairs : .obstacle,
                                        transform: matrix(object.mapFromObject),
                                        width: object.dimensionsM[0], depth: object.dimensionsM[2]))
        }
        var destinations: [String: AccessPoint] = [:]
        var points: [AccessPoint] = []
        for descriptor in metadata.destinations {
            guard destinations[descriptor.id] == nil,
                  !descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CaptureValidationError.invalid("The navigation demo has an invalid destination.")
            }
            let point = AccessPoint(
                id: destinationIDs[descriptor.id] ?? UUID(uuidString: descriptor.id) ?? UUID(),
                kind: .destination, name: descriptor.name,
                position: try position(descriptor.position), source: .manual, confidence: 1
            )
            destinations[descriptor.id] = point
            points.append(point)
        }
        guard let destination = destinations["meeting-room"] else {
            throw CaptureValidationError.invalid("The navigation demo is missing its meeting room.")
        }
        points.append(AccessPoint(
            id: UUID(uuidString: "F424C907-4530-44DD-96D7-60E9EF3E01A3")!,
            kind: .ramp, position: SIMD3(1.75, floorY, -2.1), source: .manual, confidence: 1
        ))
        points += signPlaces(capture: capture, footprints: footprints, floorY: floorY)
        let map = VenueMap(createdAt: Date(timeIntervalSince1970: 0), floorY: floorY,
                           footprints: footprints, points: points,
                           // Public example placement; the floor plan is synthetic, not an Apple venue survey.
                           geographicReference: BuildingMapReference(latitude: 37.33285, longitude: -122.00537,
                                                                     headingDegrees: 0))
        let route = RoutePlanner(map: map).route(from: startPosition, to: destination,
                                               conditions: RoutePreference.stepFree.conditions())
        return Snapshot(scene: scene, map: map, startPosition: startPosition, route: route,
                        failureReason: route == nil ? "The example building has no clear route to its meeting room." : nil)
    }

    /// Room plates beside the two doorways, as the sign reader would tag them from the hallway, so the
    /// example shows labeled doors and rooms. Floor outlines are used only to find the rooms behind.
    private static func signPlaces(capture: CaptureBundle, footprints: [Footprint], floorY: Float) -> [AccessPoint] {
        let floors = capture.surfaces.filter { $0.kind == "floor" }.map { surface -> Footprint in
            let pose = matrix(surface.mapFromSurface)
            let half = SIMD2(surface.dimensionsM[0], surface.dimensionsM[2]) / 2
            let center = SIMD2(pose.columns.3.x, pose.columns.3.z)
            return Footprint(floor: [center - half, SIMD2(center.x + half.x, center.y - half.y),
                                     center + half, SIMD2(center.x - half.x, center.y + half.y)], bottom: floorY)
        }
        let lookup = VenueMap(floorY: floorY, footprints: footprints + floors, points: [])
        let plates: [(id: String, lines: [String], sign: SIMD3<Float>, viewer: SIMD3<Float>)] = [
            ("C2A43E0B-6F1D-4C55-9C1E-2E1B8A1F0204", ["204", "MEETING ROOM"], SIMD3(2.55, 1.5, -8.45), SIMD3(1.75, 1.4, -6.8)),
            ("C2A43E0B-6F1D-4C55-9C1E-2E1B8A1F0202", ["RM 202", "RECEPTION"], SIMD3(2.55, 1.5, -2.55), SIMD3(1.75, 1.4, -4.2)),
        ]
        return plates.compactMap { plate in
            guard let reading = SignInterpreter.interpret(plate.lines), let id = UUID(uuidString: plate.id) else { return nil }
            return SignPlaceBinder.place(for: reading, text: plate.lines.joined(separator: " "), sign: plate.sign,
                                         viewer: plate.viewer, in: lookup, id: id, confidence: 1)
        }
    }

    private struct Metadata: Decodable {
        let startPosition: [Float]
        let destinations: [Destination]

        enum CodingKeys: String, CodingKey {
            case startPosition = "start_position", destinations
        }
    }

    private struct Destination: Decodable {
        let id: String
        let name: String
        let position: [Float]
    }

    private static let destinationIDs = [
        "reception": UUID(uuidString: "9F72AFCA-A6B2-4D9F-B3DA-D9D47A3C02BD")!,
        "meeting-room": UUID(uuidString: "5877C640-2FB1-4424-AD83-1B7C55B32185")!
    ]

    private static func position(_ values: [Float]) throws -> SIMD3<Float> {
        guard values.count == 3, values.allSatisfy(\.isFinite) else {
            throw CaptureValidationError.invalid("The navigation demo has an invalid position.")
        }
        return SIMD3(values[0], values[1], values[2])
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }
}
