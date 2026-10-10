import AccessCore
import RoomPlan
import simd

/// Flattens RoomPlan's output into the floor footprints the route planner works with.
enum MapBuilder {
    /// Stairs the camera spotted within this distance of stairs RoomPlan found are the same stairs.
    private static let sameStairsDistance: Float = 1.5

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
        for stairs in spottedStairs where !scannedStairs.contains(where: { simd_distance($0.center, stairs.center) < sameStairsDistance }) {
            var stairs = stairs
            stairs.bottom = floorY
            footprints.append(stairs)
        }
        return VenueMap(floorY: floorY, footprints: footprints, points: points)
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
