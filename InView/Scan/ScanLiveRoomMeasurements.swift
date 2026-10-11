import AccessCore
import RoomPlan
import simd

/// Immutable measurements prepared off the main actor, separate from final capture processing.
struct ScanLiveRoomMeasurements: Sendable {
    let floorY: Float?
    let floors: [Footprint]
    let portals: [RoomTransitionPortal]
    let observedAt: TimeInterval?

    nonisolated init(room: CapturedRoom, observedAt: TimeInterval?) {
        let heights = room.floors.map { $0.transform.translation.y }.filter(\.isFinite).sorted()
        floorY = heights.isEmpty ? nil : heights[heights.count / 2]
        floors = MapBuilder.floorFootprints(in: room)
        self.observedAt = observedAt
        guard let observedAt else { portals = []; return }
        func portal(_ surface: CapturedRoom.Surface, kind: RoomTransitionPortal.Kind) -> RoomTransitionPortal? {
            guard surface.confidence != .low else { return nil }
            let pose = surface.transform
            return RoomTransitionPortal(id: surface.identifier, kind: kind,
                center: pose.translation,
                horizontalAxis: SIMD2(pose.columns.0.x, pose.columns.0.z),
                width: surface.dimensions.x, height: surface.dimensions.y,
                observedAt: observedAt)
        }
        portals = room.doors.compactMap { portal($0, kind: .door) }
            + room.openings.compactMap { portal($0, kind: .opening) }
    }
}
