import AccessCore
import simd
import SwiftUI

/// A place pinned on the maps, like a point of interest: an elevator, a ramp or a named destination.
struct MapPlace: Identifiable, Equatable {
    let id: UUID
    let title: String
    let symbol: String
    let tint: Color
    /// Floor position as (map x, map z).
    let position: SIMD2<Float>
    /// The door a sign labeled, and the measured room behind it, lit up on the map.
    let door: SignTag.Door?
    let room: [SIMD2<Float>]?

    init(_ point: AccessPoint) {
        id = point.id
        title = point.title
        symbol = point.symbolName
        tint = point.isTooSteep ? Theme.color(for: .warning) : point.tint
        position = point.floorPoint
        door = point.sign?.door
        room = point.sign?.room
    }

    static func places(in map: VenueMap?) -> [MapPlace] {
        (map?.points ?? []).map(MapPlace.init)
    }
}

extension MapPlace {
    /// The labeled doorway's two jambs on the floor, as (x, z).
    var doorEnds: (SIMD2<Float>, SIMD2<Float>)? {
        guard let door else { return nil }
        let along = SIMD2(cos(door.yaw), sin(door.yaw)) * max(0.5, door.width) / 2
        return (door.center - along, door.center + along)
    }

    /// The floor the doorway leads into: the measured room when the scan covered it, else a short
    /// fan through the door, so a tagged room reads as a place rather than a pin in the corridor.
    var area: (outline: [SIMD2<Float>], isMeasured: Bool)? {
        if let room, room.count >= 3 { return (room, true) }
        guard let door, let (a, b) = doorEnds else { return nil }
        let normal = SIMD2(-sin(door.yaw), cos(door.yaw))
        // The place stands on the reader's side; the room is across the threshold.
        let far: Float = simd_dot(position - door.center, normal) >= 0 ? -1 : 1
        let along = simd_normalize(b - a)
        let depth = normal * far * 1.6
        return ([a, b, b + along * 0.5 + depth, a - along * 0.5 + depth], false)
    }
}
