import Foundation
import simd

/// Separately measured elevations that belong to one displayed floor. Every zone uses the
/// same registered coordinate frame; overlapping x/z positions do not connect the zones.
public struct ElevatedFloorMap: Codable, Sendable {
    public static let maximumZones = 32
    public static let maximumConnectors = 64
    public static let maximumGridCells = 2_000_000
    public static let elevationTolerance: Float = 0.05

    public var schemaVersion: Int
    public var displayFloor: Int
    public var zones: [ElevatedFloorZone]
    public var connectors: [ElevatedFloorConnector]

    public init(schemaVersion: Int = 1, displayFloor: Int, zones: [ElevatedFloorZone],
                connectors: [ElevatedFloorConnector]) {
        self.schemaVersion = schemaVersion
        self.displayFloor = displayFloor
        self.zones = zones
        self.connectors = connectors
    }

    /// A destination is assigned by its containing map, never by its nearest x/z position.
    /// Invalid duplicate identifiers are rejected by `validate()` before routing.
    public var destinationZones: [UUID: String] {
        var result: [UUID: String] = [:]
        for zone in zones { for point in zone.map.points { result[point.id] = zone.id } }
        return result
    }

    public func validate() throws {
        guard schemaVersion == 1, (-100...1_000).contains(displayFloor), !zones.isEmpty,
              zones.count <= Self.maximumZones, connectors.count <= Self.maximumConnectors else {
            throw ElevatedFloorMapError.invalidMap
        }
        var zoneIDs: Set<String> = []
        var pointIDs: Set<UUID> = []
        var footprintCount = 0, polygonPointCount = 0, gridCellCount = 0
        for zone in zones {
            guard BuildingRouteGraph.validID(zone.id), zoneIDs.insert(zone.id).inserted,
                  zone.name.map({ $0.utf8.count <= 512 }) ?? true,
                  Self.validNumber(zone.map.floorY), zone.map.createdAt.timeIntervalSince1970.isFinite,
                  zone.map.footprints.contains(where: { $0.kind == .floor }) else {
                throw ElevatedFloorMapError.invalidZone(zone.id)
            }
            footprintCount += zone.map.footprints.count
            guard footprintCount <= 10_000 else { throw ElevatedFloorMapError.excessiveSize }
            var lower = SIMD2<Float>.zero, upper = SIMD2<Float>.zero
            func include(_ position: SIMD2<Float>) {
                lower = simd_min(lower, position)
                upper = simd_max(upper, position)
            }
            for footprint in zone.map.footprints {
                guard Self.validPoint(footprint.center), Self.validPoint(footprint.size),
                      footprint.size.x > 0, footprint.size.y > 0, Self.validNumber(footprint.yaw),
                      footprint.bottom.map(Self.validNumber) ?? true,
                      footprint.height.map({ Self.validNumber($0) && $0 >= 0 }) ?? true else {
                    throw ElevatedFloorMapError.invalidZone(zone.id)
                }
                if footprint.kind == .floor {
                    guard let bottom = footprint.bottom,
                          abs(bottom - zone.map.floorY) <= Self.elevationTolerance else {
                        throw ElevatedFloorMapError.invalidZone(zone.id)
                    }
                }
                if let polygon = footprint.polygon {
                    polygonPointCount += polygon.count
                    guard (3...512).contains(polygon.count), polygon.allSatisfy(Self.validPoint) else {
                        throw ElevatedFloorMapError.invalidZone(zone.id)
                    }
                    guard polygonPointCount <= 100_000 else { throw ElevatedFloorMapError.excessiveSize }
                }
                let corners = footprint.corners
                guard corners.allSatisfy(Self.validPoint) else { throw ElevatedFloorMapError.invalidZone(zone.id) }
                corners.forEach(include)
            }
            for point in zone.map.points {
                guard pointIDs.insert(point.id).inserted, Self.validPoint(point.position),
                      abs(point.position.y - zone.map.floorY) <= Self.elevationTolerance,
                      point.name.utf8.count <= 512, point.confidence.isFinite,
                      (0...1).contains(point.confidence),
                      point.slopeDegrees.map({ $0.isFinite && $0 >= 0 && $0 < 90 }) ?? true else {
                    throw ElevatedFloorMapError.invalidZone(zone.id)
                }
                guard pointIDs.count <= 10_000 else { throw ElevatedFloorMapError.excessiveSize }
                include(point.floorPoint)
            }
            // Match OccupancyGrid's origin-inclusive bounds, 0.1 m cells and 1.5 m padding
            // before constructing any grids. Finite coordinates alone do not bound memory use.
            let width = Int(ceil((Double(upper.x) - Double(lower.x) + 3) / 0.1)) + 2
            let height = Int(ceil((Double(upper.y) - Double(lower.y) + 3) / 0.1)) + 2
            guard width <= Self.maximumGridCells, height <= Self.maximumGridCells,
                  width <= Self.maximumGridCells / height else { throw ElevatedFloorMapError.excessiveSize }
            gridCellCount += width * height
            guard gridCellCount <= Self.maximumGridCells else { throw ElevatedFloorMapError.excessiveSize }
        }
        var connectorIDs: Set<String> = []
        for connector in connectors {
            guard BuildingRouteGraph.validID(connector.id), connectorIDs.insert(connector.id).inserted,
                  connector.name.map({ $0.utf8.count <= 512 }) ?? true,
                  connector.from.zoneID != connector.to.zoneID,
                  validLocation(connector.from), validLocation(connector.to),
                  connector.estimatedSeconds.isFinite, connector.estimatedSeconds > 0,
                  connector.estimatedSeconds <= 86_400,
                  connector.minimumClearWidthMeters.map({ $0.isFinite && $0 > 0 && $0 <= 100 }) ?? true,
                  connector.slopeDegrees.map({ $0.isFinite && $0 >= 0 && $0 < 90 }) ?? true,
                  !(connector.kind == .stairs && connector.stepFree == true) else {
                throw ElevatedFloorMapError.invalidConnector(connector.id)
            }
            if connector.kind == .ramp {
                let run = simd_distance(connector.from.floorPoint, connector.to.floorPoint)
                let rise = abs(connector.to.position.y - connector.from.position.y)
                guard run > 0 else { throw ElevatedFloorMapError.invalidConnector(connector.id) }
                // Ramp geometry is a straight mapped span. A measured maximum incline
                // cannot be less than this span's own grade (allowing rounded degrees).
                let grade = atan2(rise, run) * 180 / Float.pi
                if let slope = connector.slopeDegrees, slope + 0.05 < grade {
                    throw ElevatedFloorMapError.invalidConnector(connector.id)
                }
            }
        }
    }

    func validLocation(_ location: ElevatedFloorLocation) -> Bool {
        guard Self.validPoint(location.position), let zone = zones.first(where: { $0.id == location.zoneID }) else { return false }
        return abs(location.position.y - zone.map.floorY) <= Self.elevationTolerance
    }

    static func validNumber(_ value: Float) -> Bool { value.isFinite && abs(value) <= 1_000_000 }
    static func validPoint(_ value: SIMD2<Float>) -> Bool { validNumber(value.x) && validNumber(value.y) }
    static func validPoint(_ value: SIMD3<Float>) -> Bool { validNumber(value.x) && validNumber(value.y) && validNumber(value.z) }
}

public struct ElevatedFloorZone: Codable, Sendable {
    public var id: String
    public var name: String?
    public var map: VenueMap
    public init(id: String, name: String? = nil, map: VenueMap) { self.id = id; self.name = name; self.map = map }
}

public struct ElevatedFloorLocation: Codable, Equatable, Sendable {
    public var zoneID: String
    /// A position on this zone's floor in the common registered frame, not a camera position.
    public var position: SIMD3<Float>
    public var floorPoint: SIMD2<Float> { SIMD2(position.x, position.z) }
    public init(zoneID: String, position: SIMD3<Float>) { self.zoneID = zoneID; self.position = position }
}

public enum ElevatedFloorConnectorKind: String, Codable, Sendable {
    case stairs, elevator, ramp
}

public struct ElevatedFloorConnector: Codable, Sendable {
    public var id: String
    public var name: String?
    public var kind: ElevatedFloorConnectorKind
    /// Both positions are clear approach landings on their respective measured floors.
    public var from: ElevatedFloorLocation
    public var to: ElevatedFloorLocation
    public var bidirectional: Bool
    public var availability: BuildingEdgeAvailability
    public var stepFree: Bool?
    public var minimumClearWidthMeters: Float?
    /// Measured maximum incline of an actual ramp, never inferred from an elevator's rise.
    public var slopeDegrees: Float?
    /// Includes the transition and expected waiting time, even for vertically aligned landings.
    public var estimatedSeconds: Double

    public init(id: String, name: String? = nil, kind: ElevatedFloorConnectorKind, from: ElevatedFloorLocation,
                to: ElevatedFloorLocation, bidirectional: Bool = true,
                availability: BuildingEdgeAvailability = .unknown, stepFree: Bool? = nil,
                minimumClearWidthMeters: Float? = nil, slopeDegrees: Float? = nil, estimatedSeconds: Double) {
        self.id = id; self.name = name; self.kind = kind; self.from = from; self.to = to
        self.bidirectional = bidirectional; self.availability = availability; self.stepFree = stepFree
        self.minimumClearWidthMeters = minimumClearWidthMeters; self.estimatedSeconds = estimatedSeconds
        self.slopeDegrees = slopeDegrees
    }
}

public enum ElevatedFloorMapError: Error, Equatable, LocalizedError {
    case invalidMap, invalidZone(String), invalidConnector(String), excessiveSize
    public var errorDescription: String? {
        switch self {
        case .invalidMap: "The floor map is invalid."
        case .invalidZone: "A measured area in the floor map is invalid."
        case .invalidConnector: "A connection in the floor map is invalid."
        case .excessiveSize: "The floor map is too large."
        }
    }
}

public struct ElevatedFloorSurfaceRoute: Sendable {
    public let zoneID: String
    public let elevation: Float
    public let route: Route
    public var points: [SIMD3<Float>] { route.waypoints.map { SIMD3($0.x, elevation, $0.y) } }
}

public struct ElevatedFloorTransition: Sendable {
    public let connectorID: String
    public let kind: ElevatedFloorConnectorKind
    public let from: ElevatedFloorLocation
    public let to: ElevatedFloorLocation
    public let estimatedSeconds: Double
    public let slopeDegrees: Float?
    /// An explicitly mapped straight ramp has a physical walking distance. Elevator travel
    /// and stairs remain separate transitions rather than fabricated surface polylines.
    public var rampLength: Float { kind == .ramp ? simd_distance(from.position, to.position) : 0 }
}

/// Transitions are deliberately separate from surface polylines. Consumers must not smooth or
/// draw a walking ribbon between the two landings of stairs or an elevator.
public enum ElevatedFloorRouteSegment: Sendable {
    case surface(ElevatedFloorSurfaceRoute)
    case transition(ElevatedFloorTransition)
}

public struct ElevatedFloorRoute: Sendable {
    public let displayFloor: Int
    public let destination: AccessPoint
    public let destinationZoneID: String
    public let preference: RoutePreference
    public let segments: [ElevatedFloorRouteSegment]
    public var walkingLength: Float {
        segments.reduce(0) { total, segment in
            switch segment {
            case .surface(let surface): total + surface.route.length
            case .transition(let transition): total + transition.rampLength
            }
        }
    }
    public var estimatedSeconds: Double {
        segments.reduce(0) { total, segment in
            switch segment {
            case .surface(let surface): total + surface.route.estimatedSeconds
            case .transition(let transition): total + transition.estimatedSeconds
            }
        }
    }
}
