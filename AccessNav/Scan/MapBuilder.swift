import AccessCore
import RoomPlan
import simd

/// Flattens RoomPlan's output into the floor footprints the route planner works with.
enum MapBuilder {
    /// RoomPlan surfaces have no depth, so walls are treated as this thick.
    private static let wallThickness: Float = 0.15
    /// Objects whose underside is higher than this above the floor (TVs, shelves) don't block a wheelchair.
    private static let overheadClearance: Float = 0.7

    static func build(rooms: [CapturedRoom], points: [AccessPoint], venue: VenueFrame) -> VenueMap {
        let walls = rooms.flatMap(\.walls)
        let wallBottoms = walls.map { venue.toVenue($0.transform).translation.y - $0.dimensions.y / 2 }.sorted()
        // Without walls, assume the marker sits on a table about 75 cm up.
        let floorY = wallBottoms.isEmpty ? -0.75 : wallBottoms[wallBottoms.count / 2]

        var footprints: [Footprint] = []
        for wall in walls {
            footprints.append(Footprint(kind: .wall, transform: venue.toVenue(wall.transform), width: wall.dimensions.x, depth: wallThickness))
        }
        for door in rooms.flatMap(\.doors) {
            footprints.append(Footprint(kind: .door, transform: venue.toVenue(door.transform), width: door.dimensions.x, depth: wallThickness))
        }
        for opening in rooms.flatMap(\.openings) {
            footprints.append(Footprint(kind: .opening, transform: venue.toVenue(opening.transform), width: opening.dimensions.x, depth: wallThickness))
        }
        for object in rooms.flatMap(\.objects) {
            let transform = venue.toVenue(object.transform)
            guard transform.translation.y - object.dimensions.y / 2 < floorY + overheadClearance else { continue }
            let kind: Footprint.Kind = object.category == .stairs ? .stairs : .obstacle
            footprints.append(Footprint(kind: kind, transform: transform, width: object.dimensions.x, depth: object.dimensions.z))
        }
        return VenueMap(floorY: floorY, footprints: footprints, points: points)
    }
}
