import simd

/// Puts elevator pins where they belong. RoomPlan measures door openings precisely, and elevator doors
/// usually come out as a door or an opening, so a pin near one moves to the floor just in front of it.
public enum DoorSnap {
    /// How far from a door an elevator pin may be and still snap to it.
    public static let searchRadius: Float = 1.5
    /// Where a rider waits, measured out from the door.
    public static let standOff: Float = 0.6

    public static func snap(_ point: AccessPoint, to footprints: [Footprint], floorY: Float) -> AccessPoint {
        guard point.kind == .elevator else { return point }
        let doors = footprints.filter { $0.kind == .door || $0.kind == .opening }
        guard let door = doors.min(by: { simd_distance($0.center, point.floorPoint) < simd_distance($1.center, point.floorPoint) }),
              simd_distance(door.center, point.floorPoint) <= searchRadius else { return point }

        // The door's own y axis points out of the wall; stand on whichever side the pin was.
        let normal = SIMD2(-sin(door.yaw), cos(door.yaw))
        let side: Float = simd_dot(point.floorPoint - door.center, normal) >= 0 ? 1 : -1
        let spot = door.center + normal * side * standOff
        var snapped = point
        snapped.position = SIMD3(spot.x, floorY, spot.y)
        return snapped
    }
}
