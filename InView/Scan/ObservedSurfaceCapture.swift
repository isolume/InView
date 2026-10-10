import AccessCore
import ARKit
import Foundation
import simd

/// Small measured floor and partial-wall outlines that RoomPlan may omit in open corridors.
/// Polls the shared session without replacing its delegate or retaining ARKit frames and anchors.
@MainActor
final class ObservedSurfaceCapture {
    private var surfaces = ObservedSurfaceAccumulator()
    private var lastTimestamp: TimeInterval?
    private let interval: TimeInterval = 0.75
    private let maximumNearbyAnchors = 128
    private let observationRange: Float = 12

    func update(frame: ARFrame, floorY: Float?) {
        guard floorY.map(\.isFinite) ?? true, case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1,
              lastTimestamp.map({ frame.timestamp - $0 >= interval }) ?? true else { return }
        lastTimestamp = frame.timestamp
        let camera = frame.camera.transform.columns.3
        let cameraPosition = SIMD3(camera.x, camera.y, camera.z)
        let establishedFloorY = floorY ?? surfaces.floorElevation(near: cameraPosition, within: observationRange)
        var copied = 0
        for anchor in frame.anchors {
            guard copied < maximumNearbyAnchors else { break }
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let center = plane.transform * SIMD4(plane.center, 1)
            let extent = plane.planeExtent
            let reach = hypot(extent.width, extent.height) / 2
            guard simd_distance(SIMD3(center.x, center.y, center.z), SIMD3(camera.x, camera.y, camera.z)) <= observationRange + reach else { continue }
            let localBoundary = plane.geometry.boundaryVertices
            let vertexCount = localBoundary.count
            guard (3...ObservedSurfaceGeometry.maximumBoundaryVertices).contains(vertexCount) else { continue }
            // boundaryVertices follows the plane anchor's local x/z surface, including for
            // vertical anchors. Convert using the full transform before projecting to the map.
            let boundary = (0..<vertexCount).map { index -> SIMD3<Float> in
                let point = plane.transform * SIMD4(localBoundary[index], 1)
                return SIMD3(point.x, point.y, point.z)
            }
            let lower = boundary.reduce(boundary[0], simd_min)
            let upper = boundary.reduce(boundary[0], simd_max)
            // A long floor's center can be far away even while it extends directly beneath
            // the camera. Use bounds only for the sampling distance; keep the exact outline.
            guard simd_distance(cameraPosition, simd_clamp(cameraPosition, lower, upper)) <= observationRange else { continue }
            copied += 1
            let normal = plane.transform.columns.1
            let classification: ObservedSurfaceGeometry.Classification
            switch plane.classification {
            case .floor: classification = .floor
            case .wall: classification = .wall
            case .none: classification = .unclassified
            default: classification = .other
            }
            if classification == .floor {
                let elevation = boundary.reduce(Float.zero, { $0 + $1.y }) / Float(boundary.count)
                guard (0.6...2).contains(camera.y - elevation) else { continue }
            }
            let measuredFloorY: Float
            if let establishedFloorY {
                measuredFloorY = establishedFloorY
            } else {
                // A confidently classified nearby floor can establish the elevation. An
                // unclassified horizontal plane cannot; it could be a table or lower floor.
                guard classification == .floor, plane.alignment == .horizontal else { continue }
                let elevation = boundary.reduce(Float.zero, { $0 + $1.y }) / Float(boundary.count)
                guard (0.6...2).contains(camera.y - elevation) else { continue }
                measuredFloorY = elevation
            }
            let observation = ObservedSurfaceGeometry.Plane(
                id: plane.identifier, boundary: boundary,
                normal: SIMD3(normal.x, normal.y, normal.z),
                isHorizontal: plane.alignment == .horizontal, classification: classification)
            surfaces.observe(observation, floorY: measuredFloorY, timestamp: frame.timestamp)
        }
    }

    func snapshot() -> [Footprint] { surfaces.snapshot() }

    func floorElevation(near camera: SIMD3<Float>) -> Float? {
        surfaces.floorElevation(near: camera, within: observationRange)
    }
}
