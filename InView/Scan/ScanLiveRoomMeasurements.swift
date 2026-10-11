import AccessCore
import RoomPlan
import simd

/// Immutable measurements prepared off the main actor, separate from final capture processing.
struct ScanLiveRoomMeasurements: Sendable {
    let floorY: Float?
    let floors: [Footprint]
    let observedAt: TimeInterval?

    nonisolated init(room: CapturedRoom, observedAt: TimeInterval?) {
        let heights = room.floors.map { $0.transform.translation.y }.filter(\.isFinite).sorted()
        floorY = heights.isEmpty ? nil : heights[heights.count / 2]
        floors = MapBuilder.floorFootprints(in: room)
        self.observedAt = observedAt
    }
}
