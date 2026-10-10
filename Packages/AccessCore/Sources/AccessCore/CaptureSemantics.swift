import Foundation
import simd

/// `semantics.json`: what the phone knows about a capture beyond its geometry — the volunteer's
/// confirmed access points, geographic placement, and RoomPlan labels the portable capture drops.
/// Every position is in the capture's shared ARKit session frame (meters, right-handed, +Y up), the
/// same frame as `capture.json` and `package-manifest.json`.
public struct CaptureSemantics: Codable, Equatable, Sendable {
    public static let filename = "semantics.json"
    public static let coordinateFrame = "shared_arkit_session"

    public var schemaVersion: Int
    public var coordinateFrame: String
    public var geographicReference: GeographicReference?
    public var floorY: Float?
    public var accessPoints: [AccessPointRecord]
    public var stairsFootprints: [StairsFootprint]
    public var roomplan: RoomPlanSemantics
    public var capture: CaptureInfo

    public init(schemaVersion: Int = 1, coordinateFrame: String = CaptureSemantics.coordinateFrame,
                geographicReference: GeographicReference?, floorY: Float?, accessPoints: [AccessPointRecord],
                stairsFootprints: [StairsFootprint], roomplan: RoomPlanSemantics, capture: CaptureInfo) {
        self.schemaVersion = schemaVersion
        self.coordinateFrame = coordinateFrame
        self.geographicReference = geographicReference
        self.floorY = floorY
        self.accessPoints = accessPoints
        self.stairsFootprints = stairsFootprints
        self.roomplan = roomplan
        self.capture = capture
    }

    /// Projects a reviewed venue map and RoomPlan's per-section labels into the export.
    public init(map: VenueMap?, rooms: [RoomPlanSemantics.Room], capture: CaptureInfo) {
        self.init(
            geographicReference: map?.geographicReference.map(GeographicReference.init),
            floorY: map?.floorY,
            accessPoints: (map?.points ?? []).map(AccessPointRecord.init)
                .sorted { ($0.kind, $0.id) < ($1.kind, $1.id) },
            stairsFootprints: (map?.footprints ?? []).filter { $0.kind == .stairs }.map(StairsFootprint.init),
            roomplan: RoomPlanSemantics(rooms: rooms),
            capture: capture
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", coordinateFrame = "coordinate_frame"
        case geographicReference = "geographic_reference", floorY = "floor_y", accessPoints = "access_points"
        case stairsFootprints = "stairs_footprints", roomplan, capture
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Heading is clockwise from true north to the scan's local -Z axis; the coordinate is the
    /// scan origin, not the phone.
    public struct GeographicReference: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var headingDegrees: Double
        public var horizontalAccuracyM: Double?

        public init(_ reference: BuildingMapReference) {
            latitude = reference.latitude
            longitude = reference.longitude
            headingDegrees = reference.headingDegrees
            horizontalAccuracyM = reference.horizontalAccuracyM
        }

        enum CodingKeys: String, CodingKey {
            case latitude, longitude, headingDegrees = "heading_degrees", horizontalAccuracyM = "horizontal_accuracy_m"
        }
    }

    public struct AccessPointRecord: Codable, Equatable, Sendable {
        public var id: String
        /// `elevator`, `ramp`, or `destination` (`AccessPoint.Kind`).
        public var kind: String
        public var name: String
        public var position: [Float]
        /// `detected` (vision model, confirmed by repeat sightings or the volunteer) or `manual`.
        public var source: String
        public var confidence: Float
        public var slopeDegrees: Float?
        public var requiresAssistance: Bool

        public init(_ point: AccessPoint) {
            id = point.id.uuidString
            kind = point.kind.rawValue
            name = point.title
            position = [point.position.x, point.position.y, point.position.z]
            source = point.source.rawValue
            confidence = point.confidence
            slopeDegrees = point.slopeDegrees
            requiresAssistance = point.requiresAssistance
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, name, position, source, confidence
            case slopeDegrees = "slope_degrees", requiresAssistance = "requires_assistance"
        }
    }

    /// Stairs on the floor plane, as an oriented rectangle.
    public struct StairsFootprint: Codable, Equatable, Sendable {
        /// `detected` when the vision model spotted them (RoomPlan missed them), else `roomplan`.
        public var source: String
        public var centerXZ: [Float]
        public var sizeM: [Float]
        /// Angle from +X to the rectangle's first axis, turning toward +Z, in radians.
        public var yawRadians: Float
        /// Four corners as `[x, z]`.
        public var cornersXZ: [[Float]]
        public var bottomY: Float?
        public var heightM: Float?

        public init(_ footprint: Footprint) {
            source = footprint.id == nil ? "roomplan" : "detected"
            centerXZ = [footprint.center.x, footprint.center.y]
            sizeM = [footprint.size.x, footprint.size.y]
            yawRadians = footprint.yaw
            cornersXZ = footprint.corners.map { [$0.x, $0.y] }
            bottomY = footprint.bottom
            heightM = footprint.height
        }

        enum CodingKeys: String, CodingKey {
            case source, centerXZ = "center_xz", sizeM = "size_m", yawRadians = "yaw_radians"
            case cornersXZ = "corners_xz", bottomY = "bottom_y", heightM = "height_m"
        }
    }

    public struct CaptureInfo: Codable, Equatable, Sendable {
        public var appVersion: String
        public var appBuild: String
        public var deviceModel: String
        public var systemName: String
        public var systemVersion: String
        public var floorID: String

        public init(appVersion: String, appBuild: String, deviceModel: String, systemName: String,
                    systemVersion: String, floorID: String) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.deviceModel = deviceModel
            self.systemName = systemName
            self.systemVersion = systemVersion
            self.floorID = floorID
        }

        enum CodingKeys: String, CodingKey {
            case appVersion = "app_version", appBuild = "app_build", deviceModel = "device_model"
            case systemName = "system_name", systemVersion = "system_version", floorID = "floor_id"
        }
    }
}

/// RoomPlan fields the portable `CaptureSurface`/`CaptureObject` projection leaves out. Built by
/// the app from `CapturedRoom`; plain values so it can be tested and decoded without RoomPlan.
public struct RoomPlanSemantics: Codable, Equatable, Sendable {
    public var rooms: [Room]

    public init(rooms: [Room]) { self.rooms = rooms }

    /// One RoomPlan section (`CapturedRoom`), in scan order.
    public struct Room: Codable, Equatable, Sendable {
        public var id: String
        public var story: Int?
        public var sections: [Section]
        public var surfaces: [Surface]

        public init(id: String, story: Int?, sections: [Section], surfaces: [Surface]) {
            self.id = id
            self.story = story
            self.sections = sections
            self.surfaces = surfaces
        }
    }

    /// A labeled area (kitchen, bathroom…) RoomPlan recognized within a room.
    public struct Section: Codable, Equatable, Sendable {
        public var label: String
        public var center: [Float]
        public var story: Int?

        public init(label: String, center: SIMD3<Float>, story: Int?) {
            self.label = label
            self.center = [center.x, center.y, center.z]
            self.story = story
        }
    }

    public struct Surface: Codable, Equatable, Sendable {
        public var id: String
        /// `wall`, `door`, `opening`, `window`, or `floor`.
        public var kind: String
        /// Only for doors: whether RoomPlan saw the door open.
        public var isOpen: Bool?
        /// `high`, `medium`, `low`, or `unknown`.
        public var confidence: String
        public var story: Int?
        /// The surface this one is cut into (a door's wall), when RoomPlan reports it.
        public var parentID: String?
        /// Column-major pose, like `capture.json`'s `map_from_surface`.
        public var mapFromSurface: [Float]
        public var dimensionsM: [Float]
        /// Outline corners transformed into the shared ARKit frame as `[x, y, z]`.
        public var polygonCornersM: [[Float]]

        public init(id: String, kind: String, isOpen: Bool?, confidence: String, story: Int?, parentID: String?,
                    mapFromSurface: simd_float4x4, dimensions: SIMD3<Float>, localPolygonCorners: [SIMD3<Float>]) {
            self.id = id
            self.kind = kind
            self.isOpen = isOpen
            self.confidence = confidence
            self.story = story
            self.parentID = parentID
            self.mapFromSurface = (0..<4).flatMap { column in (0..<4).map { row in mapFromSurface[column][row] } }
            dimensionsM = [dimensions.x, dimensions.y, dimensions.z]
            polygonCornersM = Self.mapCorners(localPolygonCorners, by: mapFromSurface)
        }

        /// RoomPlan reports polygon corners in the surface's own frame; move them into the map frame.
        public static func mapCorners(_ corners: [SIMD3<Float>], by transform: simd_float4x4) -> [[Float]] {
            corners.map { corner in
                let mapped = transform * SIMD4(corner, 1)
                return [mapped.x, mapped.y, mapped.z]
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, isOpen = "is_open", confidence, story, parentID = "parent_id"
            case mapFromSurface = "map_from_surface", dimensionsM = "dimensions_m", polygonCornersM = "polygon_corners_m"
        }
    }
}
