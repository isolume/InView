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
        /// A window in a wall. Drawn on plans; the wall around it is what blocks.
        case window
        /// Measured floor coverage. Maps with floors keep routes within their union.
        case floor

        var blocksWheelchairs: Bool { self == .wall || self == .obstacle || self == .stairs || self == .window }
        var isPassage: Bool { self == .door || self == .opening }
    }

    /// Rough furniture type, so maps can draw a table as a table rather than a box.
    public enum Furniture: String, Codable, CaseIterable, Sendable {
        case table
        case chair
        case sofa
        case bed
        case storage
        /// Fridges, stoves, ovens, dishwashers, washers.
        case appliance
        case sink
        case toilet
        case bathtub
        case television
        case fireplace
    }

    public var kind: Kind
    /// Set for features the camera spotted, linking them to the photo they were spotted in.
    public var id: UUID?
    /// Center on the floor, as (x, z).
    public var center: SIMD2<Float>
    /// Extent along the footprint's own x axis, then across it.
    public var size: SIMD2<Float>
    /// Angle from +x to the footprint's x axis, turning toward +z.
    public var yaw: Float
    /// What an obstacle is, when known.
    public var furniture: Furniture?
    /// Height of the underside above the map origin, and the object's own height, when known.
    public var bottom: Float?
    public var height: Float?
    /// The exact outline on the floor, as (x, z), for floors whose shape isn't a rectangle. `center`,
    /// `size` and `yaw` still describe the bounding rectangle.
    public var polygon: [SIMD2<Float>]?

    public init(
        kind: Kind,
        center: SIMD2<Float>,
        size: SIMD2<Float>,
        yaw: Float,
        furniture: Furniture? = nil,
        bottom: Float? = nil,
        height: Float? = nil,
        id: UUID? = nil,
        polygon: [SIMD2<Float>]? = nil
    ) {
        self.kind = kind
        self.id = id
        self.center = center
        self.size = size
        self.yaw = yaw
        self.furniture = furniture
        self.bottom = bottom
        self.height = height
        self.polygon = polygon
    }

    /// A floor from its outline. The bounding rectangle is axis-aligned.
    public init(floor outline: [SIMD2<Float>], bottom: Float) {
        var lower = outline.first ?? .zero, upper = lower
        for point in outline {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        self.init(kind: .floor, center: (lower + upper) / 2, size: upper - lower, yaw: 0, bottom: bottom, height: 0, polygon: outline)
    }

    /// Projects a 3D box (RoomPlan surface or object) onto the floor.
    /// - Parameters:
    ///   - transform: The box's pose in map coordinates, centered on the box.
    ///   - dimensions: The box's extent along its local x, y and z axes.
    ///   - depth: Overrides the z extent, for surfaces RoomPlan reports as flat.
    public init(kind: Kind, transform: simd_float4x4, dimensions: SIMD3<Float>, depth: Float? = nil, furniture: Furniture? = nil) {
        let axis = SIMD2(transform.columns.0.x, transform.columns.0.z)
        self.init(
            kind: kind,
            center: SIMD2(transform.columns.3.x, transform.columns.3.z),
            size: SIMD2(dimensions.x, depth ?? dimensions.z),
            yaw: simd_length(axis) > 1e-4 ? atan2(axis.y, axis.x) : 0,
            furniture: furniture,
            bottom: transform.columns.3.y - dimensions.y / 2,
            height: dimensions.y
        )
    }

    /// Projects a legacy floor rectangle when its vertical measurements are unavailable.
    public init(kind: Kind, transform: simd_float4x4, width: Float, depth: Float) {
        let axis = SIMD2(transform.columns.0.x, transform.columns.0.z)
        self.init(
            kind: kind,
            center: SIMD2(transform.columns.3.x, transform.columns.3.z),
            size: SIMD2(width, depth),
            yaw: simd_length(axis) > 1e-4 ? atan2(axis.y, axis.x) : 0
        )
    }

    /// Maps a point in the footprint's own axes (x along `size.x`, y along `size.y`) onto the floor.
    public func floorPoint(local point: SIMD2<Float>) -> SIMD2<Float> {
        let c = cos(yaw), s = sin(yaw)
        return center + SIMD2(c, s) * point.x + SIMD2(-s, c) * point.y
    }

    /// Expresses a floor point in this footprint's own axes.
    public func local(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let offset = point - center
        let c = cos(yaw), s = sin(yaw)
        return SIMD2(offset.x * c + offset.y * s, -offset.x * s + offset.y * c)
    }

    /// The outline on the floor: the polygon when there is one, else the rectangle's corners.
    public var corners: [SIMD2<Float>] {
        if let polygon, polygon.count >= 3 { return polygon }
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
    /// Geographic placement of the scan's origin; existing indoor maps may have none.
    public var geographicReference: BuildingMapReference?
    /// New scans require observed floor; nil preserves floorless legacy-map compatibility.
    public var requiresMeasuredFloorCoverage: Bool?
    /// A nonrigid backend correction needs localization against that corrected map before live AR routing.
    public var requiresOptimizedLocalization: Bool?

    public init(
        createdAt: Date = .now,
        floorY: Float,
        footprints: [Footprint],
        points: [AccessPoint],
        geographicReference: BuildingMapReference? = nil,
        requiresMeasuredFloorCoverage: Bool? = nil
    ) {
        self.createdAt = createdAt
        self.floorY = floorY
        self.footprints = footprints
        self.points = points
        self.geographicReference = geographicReference
        self.requiresMeasuredFloorCoverage = requiresMeasuredFloorCoverage
    }
}

extension VenueMap {
    /// Adds a place, or replaces the one with the same id where it is in the list. A new elevator,
    /// or a place changed into one, moves in front of the nearest measured door, as scanned ones do.
    public mutating func place(_ point: AccessPoint) {
        guard let index = points.firstIndex(where: { $0.id == point.id }) else {
            points.append(DoorSnap.snap(point, to: footprints, floorY: floorY))
            return
        }
        points[index] = points[index].kind == .elevator ? point : DoorSnap.snap(point, to: footprints, floorY: floorY)
    }

    public mutating func removePoint(id: UUID) {
        points.removeAll { $0.id == id }
    }
}
