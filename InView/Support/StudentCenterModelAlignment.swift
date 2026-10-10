import AccessCore
import simd
import Foundation

/// A first visual registration of the estimated walkthrough model, using the supplied elevator markers.
/// This transform is for display only. Map geometry and routing coordinates remain unchanged.
enum StudentCenterModelAlignment {
    static let qualityTitle = "Approximate alignment"
    static let qualityDescription = "Aligned at the elevators; other areas are estimated."

    // Floor-plane midpoints of the paired "Lift · sliding panel" nodes in floors-2-3/floor-2.glb.
    // Per-floor GLB and USDZ assets retain a shared Y-up coordinate frame: Floor 2 at 0, Floor 3 at 4.
    static let firstModelAnchor = SIMD3<Float>(-1.30, 0, 8.82)
    static let secondModelAnchor = SIMD3<Float>(1.07, 0, 8.82)
    static let firstElevatorID = UUID(uuidString: "0252CB01-29DC-4136-8A98-AB2076782D1E")!
    static let secondElevatorID = UUID(uuidString: "457D4F40-982C-48BA-854F-F35DCF158A80")!

    struct Metadata {
        let uniformScale: Float
        let rotationDegrees: Float
        let matchedLandmarks = 2
        let isApproximate = true
    }

    static func transform(for map: VenueMap, floor: Int = 2) -> simd_float4x4? {
        guard floor == 2 || floor == 3 else { return nil }
        return registration(for: map)?.transform
    }

    /// Floor 3 keeps its authored elevation under the same registration, with no fabricated routing map.
    static func displayFloorY(for map: VenueMap, floor: Int) -> Float? {
        guard let transform = transform(for: map, floor: floor),
              let elevation = StudentCenterCatalog.modelFloorY(for: floor) else { return nil }
        return (transform * SIMD4<Float>(0, elevation, 0, 1)).y
    }

    static func metadata(for map: VenueMap) -> Metadata? {
        registration(for: map)?.metadata
    }

    private static func registration(for map: VenueMap) -> (transform: simd_float4x4, metadata: Metadata)? {
        let first = map.points.filter { $0.id == firstElevatorID }
        let second = map.points.filter { $0.id == secondElevatorID }
        guard first.count == 1, second.count == 1,
              first[0].kind == .elevator, second[0].kind == .elevator,
              map.floorY.isFinite, abs(map.floorY) <= 1_000 else { return nil }
        let destinations = [first[0].position, second[0].position]
        guard destinations.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                && abs($0.x) <= 10_000 && abs($0.z) <= 10_000
                && abs($0.y - map.floorY) <= 0.05
        }) else { return nil }

        let sourceA = SIMD2(firstModelAnchor.x, firstModelAnchor.z)
        let sourceB = SIMD2(secondModelAnchor.x, secondModelAnchor.z)
        let destinationA = first[0].floorPoint
        let destinationB = second[0].floorPoint
        let sourceDelta = sourceB - sourceA
        let destinationDelta = destinationB - destinationA
        let scale = simd_length(destinationDelta) / simd_length(sourceDelta)
        guard scale.isFinite, (0.5...2).contains(scale) else { return nil }

        let angle = atan2(destinationDelta.y, destinationDelta.x) - atan2(sourceDelta.y, sourceDelta.x)
        let c = cos(angle) * scale
        let s = sin(angle) * scale
        let rotatedA = SIMD2(c * sourceA.x - s * sourceA.y, s * sourceA.x + c * sourceA.y)
        let translation = destinationA - rotatedA
        guard translation.x.isFinite, translation.y.isFinite else { return nil }

        // Uniform scale preserves the model's proportions; the main model floor maps to scan.floorY.
        let transform = simd_float4x4(columns: (
            SIMD4(c, 0, s, 0), SIMD4(0, scale, 0, 0), SIMD4(-s, 0, c, 0),
            SIMD4(translation.x, map.floorY, translation.y, 1)
        ))
        return (transform, Metadata(uniformScale: scale, rotationDegrees: angle * 180 / .pi))
    }
}
