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

    init(_ point: AccessPoint) {
        id = point.id
        title = point.title
        symbol = point.kind.symbolName
        tint = point.isTooSteep ? Theme.color(for: .warning) : point.kind.tint
        position = point.floorPoint
    }

    static func places(in map: VenueMap?) -> [MapPlace] {
        (map?.points ?? []).map(MapPlace.init)
    }
}
