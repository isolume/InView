import ARKit
import AccessCore

/// Watches LiDAR depth for things in the way that the saved map doesn't know about, and remembers
/// them for a while so the route doesn't swing back the moment they leave the camera's view.
@MainActor
final class ObstacleTracker {
    private static let memory: TimeInterval = 20
    private static let sameObstacleDistance: Float = 0.6
    /// Use every Nth depth pixel in each direction; plenty for chair-sized things.
    private static let depthStride = 4
    private static let depthRange: ClosedRange<Float> = 0.3...5

    private var tracked: [(position: SIMD2<Float>, lastSeen: Date)] = []

    var obstacles: [SIMD2<Float>] { tracked.map(\.position) }

    /// Looks for obstacles along the route ahead. Returns true when a new one appeared.
    func update(with frame: ARFrame, route: [SIMD2<Float>], floorY: Float) -> Bool {
        tracked.removeAll { Date.now.timeIntervalSince($0.lastSeen) > Self.memory }
        guard let points = Self.depthPoints(in: frame) else { return false }
        var appeared = false
        for found in ObstacleFinder.obstacles(in: points, along: route, floorY: floorY) {
            if let index = tracked.firstIndex(where: { simd_distance($0.position, found) < Self.sameObstacleDistance }) {
                tracked[index] = (found, .now)
            } else {
                tracked.append((found, .now))
                appeared = true
            }
        }
        return appeared
    }

    func reset() {
        tracked = []
    }

    /// World positions of confident LiDAR depth samples.
    private static func depthPoints(in frame: ARFrame) -> [SIMD3<Float>]? {
        guard let depth = frame.sceneDepth else { return nil }
        let depthMap = depth.depthMap
        let confidenceMap = depth.confidenceMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let confidenceBase = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)
        let width = CVPixelBufferGetWidth(depthMap), height = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceRowBytes = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0

        // The depth map is a downscaled copy of the camera image, so scale the intrinsics to match.
        let camera = frame.camera
        let scaleX = Float(width) / Float(camera.imageResolution.width)
        let scaleY = Float(height) / Float(camera.imageResolution.height)
        let fx = camera.intrinsics[0][0] * scaleX, fy = camera.intrinsics[1][1] * scaleY
        let cx = camera.intrinsics[2][0] * scaleX, cy = camera.intrinsics[2][1] * scaleY
        let highConfidence = UInt8(ARConfidenceLevel.high.rawValue)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity((width / depthStride) * (height / depthStride))
        for v in stride(from: 0, to: height, by: depthStride) {
            let depthRow = depthBase.advanced(by: v * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?.advanced(by: v * confidenceRowBytes).assumingMemoryBound(to: UInt8.self)
            for u in stride(from: 0, to: width, by: depthStride) {
                if let confidenceRow, confidenceRow[u] < highConfidence { continue }
                let d = depthRow[u]
                guard depthRange.contains(d) else { continue }
                // Camera space looks down -z with +y up; depth rows grow downward.
                let local = SIMD4<Float>((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d, 1)
                let world = camera.transform * local
                points.append(SIMD3(world.x, world.y, world.z))
            }
        }
        return points
    }
}
