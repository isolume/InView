import AccessCore
import Foundation
import RoomPlan
import simd

/// Flattens RoomPlan's output into the floor footprints the route planner works with.
enum MapBuilder {
    /// RoomPlan surfaces have no depth, so walls are treated as this thick.
    private static let wallThickness: Float = 0.15
    /// Objects whose underside is higher than this above the floor (TVs, shelves) don't block a wheelchair.
    private static let overheadClearance: Float = 0.7
    /// The world origin is the phone where the scan started, usually held about this high.
    private static let assumedPhoneHeight: Float = 1.3

    static func build(rooms: [CapturedRoom], points: [AccessPoint]) -> VenueMap {
        let walls = latest(rooms.flatMap(\.walls), id: \.identifier)
        let floorY = median(walls.map { $0.transform.translation.y - $0.dimensions.y / 2 })
            ?? median(latest(rooms.flatMap(\.floors), id: \.identifier).map(\.transform.translation.y))
            ?? -assumedPhoneHeight

        var footprints: [Footprint] = []
        for wall in walls {
            footprints.append(Footprint(kind: .wall, transform: wall.transform, width: wall.dimensions.x, depth: wallThickness))
        }
        for door in latest(rooms.flatMap(\.doors), id: \.identifier) {
            footprints.append(Footprint(kind: .door, transform: door.transform, width: door.dimensions.x, depth: wallThickness))
        }
        for opening in latest(rooms.flatMap(\.openings), id: \.identifier) {
            footprints.append(Footprint(kind: .opening, transform: opening.transform, width: opening.dimensions.x, depth: wallThickness))
        }
        for object in latest(rooms.flatMap(\.objects), id: \.identifier) {
            guard object.transform.translation.y - object.dimensions.y / 2 < floorY + overheadClearance else { continue }
            let kind: Footprint.Kind = object.category == .stairs ? .stairs : .obstacle
            footprints.append(Footprint(kind: kind, transform: object.transform, width: object.dimensions.x, depth: object.dimensions.z))
        }
        return VenueMap(floorY: floorY, footprints: footprints, points: points)
    }

    /// Repeated RoomPlan sections can refine the same item; match the exported scene's latest pose.
    private static func latest<T>(_ items: [T], id: KeyPath<T, UUID>) -> [T] {
        var values: [UUID: T] = [:]
        for item in items { values[item[keyPath: id]] = item }
        return values.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { values[$0] }
    }

    private static func median(_ values: [Float]) -> Float? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }
}
