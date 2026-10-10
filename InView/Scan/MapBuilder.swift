import AccessCore
import RoomPlan
import simd

/// Flattens RoomPlan's output into the floor footprints the route planner works with.
enum MapBuilder {
    /// Stairs the camera spotted that overlap stairs RoomPlan found (allowing this much slack) are the same stairs.
    private static let sameStairsSlack: Float = 1

    /// RoomPlan surfaces have no depth, so walls are treated as this thick.
    private static let wallThickness: Float = 0.15
    /// Objects whose underside is higher than this above the floor (TVs, shelves) don't block a wheelchair.
    private static let overheadClearance: Float = 0.7
    /// The world origin is the phone where the scan started, usually held about this high.
    private static let assumedPhoneHeight: Float = 1.3

    /// - Parameter spottedStairs: Stairs found by the vision model, added where RoomPlan missed them.
    static func build(rooms: [CapturedRoom], points: [AccessPoint], spottedStairs: [Footprint] = []) -> VenueMap {
        let walls = rooms.flatMap(\.walls)
        let floorY = median(walls.map { $0.transform.translation.y - $0.dimensions.y / 2 })
            ?? median(rooms.flatMap(\.floors).map(\.transform.translation.y))
            ?? -assumedPhoneHeight

        var footprints: [Footprint] = []
        for wall in walls {
            footprints.append(Footprint(kind: .wall, transform: wall.transform, dimensions: wall.dimensions, depth: wallThickness))
        }
        for door in rooms.flatMap(\.doors) {
            footprints.append(Footprint(kind: .door, transform: door.transform, dimensions: door.dimensions, depth: wallThickness))
        }
        for opening in rooms.flatMap(\.openings) {
            footprints.append(Footprint(kind: .opening, transform: opening.transform, dimensions: opening.dimensions, depth: wallThickness))
        }
        for object in rooms.flatMap(\.objects) {
            guard object.transform.translation.y - object.dimensions.y / 2 < floorY + overheadClearance else { continue }
            let kind: Footprint.Kind = object.category == .stairs ? .stairs : .obstacle
            footprints.append(Footprint(kind: kind, transform: object.transform, dimensions: object.dimensions, furniture: furniture(for: object.category)))
        }
        let scannedStairs = footprints.filter { $0.kind == .stairs }
        for stairs in spottedStairs where !scannedStairs.contains(where: { overlaps($0, stairs) }) {
            var stairs = stairs
            stairs.bottom = floorY
            footprints.append(stairs)
        }
        // RoomPlan measures door openings precisely; move elevator pins in front of the doors they belong to.
        let snapped = points.map { DoorSnap.snap($0, to: footprints, floorY: floorY) }
        return VenueMap(floorY: floorY, footprints: footprints, points: snapped)
    }

    /// Whether two footprints' areas come within `sameStairsSlack` of each other.
    private static func overlaps(_ a: Footprint, _ b: Footprint) -> Bool {
        let reach = (simd_length(a.size) + simd_length(b.size)) / 2 + sameStairsSlack
        guard simd_distance(a.center, b.center) < reach else { return false }
        // Close enough by bounding circles; confirm with a corner or center inside the other, grown by the slack.
        let inside = { (point: SIMD2<Float>, footprint: Footprint) -> Bool in
            let local = footprint.local(point)
            return abs(local.x) <= footprint.size.x / 2 + sameStairsSlack && abs(local.y) <= footprint.size.y / 2 + sameStairsSlack
        }
        return ([b.center] + b.corners).contains { inside($0, a) } || ([a.center] + a.corners).contains { inside($0, b) }
    }

    private static func furniture(for category: CapturedRoom.Object.Category) -> Footprint.Furniture? {
        switch category {
        case .table: .table
        case .chair: .chair
        case .sofa: .sofa
        case .bed: .bed
        case .storage: .storage
        case .refrigerator, .stove, .oven, .dishwasher, .washerDryer: .appliance
        case .sink: .sink
        case .toilet: .toilet
        case .bathtub: .bathtub
        case .television: .television
        case .fireplace: .fireplace
        case .stairs: nil
        @unknown default: nil
        }
    }

    private static func median(_ values: [Float]) -> Float? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }
}
