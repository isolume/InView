import AccessCore
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
