import AccessCore
import simd

extension GeminiAssistantClient.Context {
    struct Floor {
        let level: Int
        /// What map, if any, the floor has, like "3D model and partial floor scan".
        let summary: String
        /// Measured points from the map the floor opens with.
        let points: [AccessPoint]
        let landmarks: [StudentCenterCatalog.ModelLandmark]
    }

    /// The places each floor shows when opened. Walkthrough landmarks share one model frame, so each can
    /// name its nearest neighbours; measured points sit in their scan's own frame and aren't compared with them.
    /// - Parameter user: Where the camera found the person, in the frame of that floor's measured points.
    init(buildingName: String, currentFloor: Int, floors: [Floor], user: (floor: Int, position: SIMD2<Float>)? = nil) {
        var places: [GeminiAssistantClient.Place] = []
        for floor in floors {
            for point in floor.points {
                let distance = user.flatMap { $0.floor == floor.level ? simd_distance($0.position, point.floorPoint) : nil }
                places.append(.init(id: point.id, name: point.title, kind: point.kind.title.lowercased(),
                                    floor: floor.level, nearby: [], note: Self.note(for: point), distance: distance))
            }
            // Matches the map: a floor's measured elevators replace the model's "Lifts".
            let hidesLifts = floor.points.contains { $0.kind == .elevator }
            for landmark in floor.landmarks where !(hidesLifts && landmark.title == "Lifts") {
                let nearby = floor.landmarks
                    .filter { $0.title != landmark.title }
                    .sorted { Self.distance($0, landmark) < Self.distance($1, landmark) }
                    .prefix(2).map(\.title)
                places.append(.init(id: landmark.id, name: landmark.title,
                                    kind: landmark.title == "Lifts" ? "elevators" : "place",
                                    floor: floor.level, nearby: nearby, note: nil))
            }
        }
        self.init(buildingName: buildingName, currentFloor: currentFloor,
                  floorSummary: floors.map { "Floor \($0.level): \($0.summary)" }, places: places)
    }

    private static func distance(_ a: StudentCenterCatalog.ModelLandmark, _ b: StudentCenterCatalog.ModelLandmark) -> Float {
        simd_distance(SIMD2(a.position.x, a.position.z), SIMD2(b.position.x, b.position.z))
    }

    private static func note(for point: AccessPoint) -> String? {
        if point.requiresAssistance { return "needs a staff member to operate" }
        guard let slope = point.slopeDegrees else { return nil }
        return point.isTooSteep
            ? String(format: "steep ramp, %.1f degrees", slope)
            : String(format: "gentle ramp, %.1f degrees", slope)
    }
}
