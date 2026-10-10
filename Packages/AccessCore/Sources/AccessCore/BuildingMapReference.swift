import Foundation

public struct GeographicCoordinate: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Places the scan's unchanged local floor coordinates on a geographic map.
/// Heading is clockwise from true north to the scan's local -Z axis.
public struct BuildingMapReference: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var headingDegrees: Double
    public var horizontalAccuracyM: Double?

    public init(
        latitude: Double,
        longitude: Double,
        headingDegrees: Double = 0,
        horizontalAccuracyM: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.headingDegrees = headingDegrees
        self.horizontalAccuracyM = horizontalAccuracyM
    }

    public func validate() throws {
        try Self.validate(GeographicCoordinate(latitude: latitude, longitude: longitude))
        guard headingDegrees.isFinite else { throw BuildingMapReferenceError.invalidHeading }
        if let accuracy = horizontalAccuracyM {
            guard accuracy.isFinite, accuracy >= 0 else { throw BuildingMapReferenceError.invalidAccuracy }
        }
    }

    /// Converts local (x, z) meters to latitude and longitude.
    /// The Mercator scale is corrected at the origin, suitable for a building-sized scan.
    public func coordinate(for mapPoint: SIMD2<Float>) throws -> GeographicCoordinate {
        try validate()
        guard mapPoint.x.isFinite, mapPoint.y.isFinite else {
            throw BuildingMapReferenceError.invalidMapPoint
        }

        let angle = headingRadians
        let east = Double(mapPoint.x) * cos(angle) - Double(mapPoint.y) * sin(angle)
        let north = -Double(mapPoint.x) * sin(angle) - Double(mapPoint.y) * cos(angle)
        let scale = cos(latitude * Self.radiansPerDegree)
        let projectedY = Self.projectedY(latitude) + north / scale
        guard projectedY.isFinite, abs(projectedY) < Self.maximumProjectedY else {
            throw BuildingMapReferenceError.outsideMapCoverage
        }

        let coordinate = GeographicCoordinate(
            latitude: atan(sinh(projectedY / Self.earthRadius)) / Self.radiansPerDegree,
            longitude: Self.wrappedDegrees(longitude + east / scale / Self.earthRadius / Self.radiansPerDegree)
        )
        try Self.validate(coordinate)
        return coordinate
    }

    /// Converts a geographic coordinate into the scan's original local (x, z) meters.
    public func mapPoint(for coordinate: GeographicCoordinate) throws -> SIMD2<Float> {
        try validate()
        try Self.validate(coordinate)

        let scale = cos(latitude * Self.radiansPerDegree)
        let east = Self.wrappedDegrees(coordinate.longitude - longitude) * Self.radiansPerDegree * Self.earthRadius * scale
        let north = (Self.projectedY(coordinate.latitude) - Self.projectedY(latitude)) * scale
        let angle = headingRadians
        let point = SIMD2<Float>(
            Float(east * cos(angle) - north * sin(angle)),
            Float(-east * sin(angle) - north * cos(angle))
        )
        guard point.x.isFinite, point.y.isFinite else { throw BuildingMapReferenceError.invalidMapPoint }
        return point
    }

    private var headingRadians: Double {
        headingDegrees.truncatingRemainder(dividingBy: 360) * Self.radiansPerDegree
    }

    // WGS84's semi-major axis, used by the map renderers' Web Mercator projection.
    private static let earthRadius = 6_378_137.0
    private static let radiansPerDegree = Double.pi / 180
    private static let maximumLatitude = 85.05112878
    private static let maximumProjectedY = projectedY(maximumLatitude)

    private static func validate(_ coordinate: GeographicCoordinate) throws {
        guard coordinate.latitude.isFinite, abs(coordinate.latitude) < maximumLatitude else {
            throw BuildingMapReferenceError.invalidLatitude
        }
        guard coordinate.longitude.isFinite, (-180...180).contains(coordinate.longitude) else {
            throw BuildingMapReferenceError.invalidLongitude
        }
    }

    private static func projectedY(_ latitude: Double) -> Double {
        earthRadius * log(tan(.pi / 4 + latitude * radiansPerDegree / 2))
    }

    private static func wrappedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        if value >= 180 { return value - 360 }
        if value < -180 { return value + 360 }
        return value
    }
}

public enum BuildingMapReferenceError: LocalizedError, Equatable, Sendable {
    case invalidLatitude
    case invalidLongitude
    case invalidHeading
    case invalidAccuracy
    case invalidMapPoint
    case outsideMapCoverage

    public var errorDescription: String? {
        switch self {
        case .invalidLatitude, .invalidLongitude, .outsideMapCoverage:
            return "Choose a location within the map's coverage."
        case .invalidHeading:
            return "Choose a valid building orientation."
        case .invalidAccuracy:
            return "The location accuracy is invalid."
        case .invalidMapPoint:
            return "The building position is invalid."
        }
    }
}
