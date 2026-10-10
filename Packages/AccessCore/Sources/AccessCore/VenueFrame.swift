import simd

/// A gravity-aligned coordinate frame anchored at the printed check-in marker.
///
/// Every AR session starts with its own arbitrary world origin. Storing the map in this frame
/// means a later session only has to find the marker to line the saved map up with the room.
public struct VenueFrame: Sendable {
    public let worldFromVenue: simd_float4x4
    public let venueFromWorld: simd_float4x4

    /// - Parameters:
    ///   - origin: World position of the venue origin.
    ///   - heading: World direction whose horizontal part becomes venue +x.
    public init(origin: SIMD3<Float>, heading: SIMD3<Float>) {
        var x = SIMD3<Float>(heading.x, 0, heading.z)
        x = simd_length(x) > 1e-4 ? simd_normalize(x) : SIMD3(1, 0, 0)
        let y = SIMD3<Float>(0, 1, 0)
        let z = simd_cross(x, y)
        worldFromVenue = simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1))
        venueFromWorld = worldFromVenue.inverse
    }

    /// Averages several sightings of the marker to smooth out detection jitter.
    ///
    /// Uses the marker's x axis for heading, which stays horizontal whether the print lies flat
    /// on a table or hangs on a wall.
    public init?(markerTransforms: [simd_float4x4]) {
        guard !markerTransforms.isEmpty else { return nil }
        var origin = SIMD3<Float>.zero
        var heading = SIMD3<Float>.zero
        for transform in markerTransforms {
            origin += transform.translation
            let axis = SIMD3(transform.columns.0.x, 0, transform.columns.0.z)
            if simd_length(axis) > 1e-4 { heading += simd_normalize(axis) }
        }
        self.init(origin: origin / Float(markerTransforms.count), heading: heading)
    }

    public func toVenue(_ point: SIMD3<Float>) -> SIMD3<Float> {
        (venueFromWorld * SIMD4(point, 1)).xyz
    }

    public func toVenue(_ transform: simd_float4x4) -> simd_float4x4 {
        venueFromWorld * transform
    }

    public func toWorld(_ point: SIMD3<Float>) -> SIMD3<Float> {
        (worldFromVenue * SIMD4(point, 1)).xyz
    }
}

extension simd_float4x4 {
    public var translation: SIMD3<Float> { columns.3.xyz }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
