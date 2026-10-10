import Foundation
import simd

/// An oriented rectangle on the floor plane: the top-down shadow of a wall, door or object.
public struct Footprint: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case wall
        case obstacle
        case stairs
        case door
        case opening

        var blocksWheelchairs: Bool { self == .wall || self == .obstacle || self == .stairs }
        var isPassage: Bool { self == .door || self == .opening }
    }

    public var kind: Kind
    /// Center on the floor, as (x, z).
    public var center: SIMD2<Float>
    /// Extent along the footprint's own x axis, then across it.
    public var size: SIMD2<Float>
    /// Angle from +x to the footprint's x axis, turning toward +z.
    public var yaw: Float

    public init(kind: Kind, center: SIMD2<Float>, size: SIMD2<Float>, yaw: Float) {
        self.kind = kind
        self.center = center
        self.size = size
        self.yaw = yaw
    }

    /// Projects a 3D box (RoomPlan surface or object) onto the floor.
    /// - Parameters:
    ///   - transform: The box's pose in map coordinates.
    ///   - width: Extent along the box's local x axis.
    ///   - depth: Extent along the box's local z axis.
    public init(kind: Kind, transform: simd_float4x4, width: Float, depth: Float) {
        let axis = SIMD2(transform.columns.0.x, transform.columns.0.z)
        self.init(
            kind: kind,
            center: SIMD2(transform.columns.3.x, transform.columns.3.z),
            size: SIMD2(width, depth),
            yaw: simd_length(axis) > 1e-4 ? atan2(axis.y, axis.x) : 0
        )
    }

    /// Expresses a floor point in this footprint's own axes.
    public func local(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let offset = point - center
        let c = cos(yaw), s = sin(yaw)
        return SIMD2(offset.x * c + offset.y * s, -offset.x * s + offset.y * c)
    }

    public var corners: [SIMD2<Float>] {
        let c = cos(yaw), s = sin(yaw)
        let along = SIMD2(c, s) * size.x / 2
        let across = SIMD2(-s, c) * size.y / 2
        return [center + along + across, center - along + across, center - along - across, center + along - across]
    }
}

/// Everything a navigation session needs, in the scan session's world coordinates.
/// Navigation relocalizes against the saved ARWorldMap to get back into the same space.
public struct VenueMap: Codable, Sendable {
    public var createdAt: Date
    /// Floor height. y = 0 is where the phone was when the scan started.
    public var floorY: Float
    public var footprints: [Footprint]
    public var points: [AccessPoint]

    public init(createdAt: Date = .now, floorY: Float, footprints: [Footprint], points: [AccessPoint]) {
        self.createdAt = createdAt
        self.floorY = floorY
        self.footprints = footprints
        self.points = points
    }
}
