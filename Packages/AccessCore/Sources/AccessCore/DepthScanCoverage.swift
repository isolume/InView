import Foundation
import simd

/// A supported, directly measured depth pixel in sensor-native image coordinates.
/// No plane fitting, interpolation, or inferred unseen surface is included.
public struct DepthScanCoverageSample: Sendable {
    public let point: SIMD3<Float>
    public let normal: SIMD3<Float>
    public let column: Int
    public let row: Int

    public init(point: SIMD3<Float>, normal: SIMD3<Float>, column: Int, row: Int) {
        self.point = point; self.normal = normal; self.column = column; self.row = row
    }
}

struct CoverageObservation: Sendable {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
    var capturedAt: TimeInterval
}

// These bounded display algorithms run repeatedly while the camera is active.
// Optimize their hot functions in Debug too, so testing a scan on a phone does not
// spend hundreds of milliseconds processing a frame. Other app code keeps its
// normal Debug settings and diagnostics.

/// Immutable, bounded evidence for highlighting currently visible captured surfaces.
/// This is display coverage, not a completeness estimate or an archive of the scan.
public struct DepthScanCoverageSnapshot: Sendable {
    fileprivate var cells: [SIMD3<Int>: [CoverageObservation]]

    /// Retained spatial bins. A bin's entire volume is never considered captured.
    public var count: Int { cells.count }
    public var isEmpty: Bool { cells.isEmpty }
    public var sampleCount: Int { cells.values.reduce(0) { $0 + $1.count } }

    @_optimize(speed)
    public func contains(point: SIMD3<Float>, normal: SIMD3<Float>? = nil) -> Bool {
        capturedAt(point: point, normal: normal) != nil
    }

    /// First saved observation of a matching measured surface, in capture-session time.
    /// Call with a current depth measurement so an occluding or changed surface hides
    /// the highlight immediately. Unsupported points and malformed normals fail closed.
    @_optimize(speed)
    public func capturedAt(point: SIMD3<Float>, normal: SIMD3<Float>? = nil) -> TimeInterval? {
        matchingObservation(point: point, normal: normal)?.capturedAt
    }

    @_optimize(speed)
    func matchingObservation(point: SIMD3<Float>, normal: SIMD3<Float>? = nil, nearest: Bool = false) -> CoverageObservation? {
        guard coveragePointIsValid(point) else { return nil }
        let retainedCells = cells
        var unitNormal: SIMD3<Float>?
        if let normal {
            let length = simd_length(normal)
            guard length.isFinite, length > 1e-6 else { return nil }
            unitNormal = normal / length
        }
        let localKey = coverageCell(point)
        var local: CoverageObservation?
        var localDistance: Float = .infinity
        if nearest, let observations = retainedCells[localKey] {
            for observation in observations where coverageMatches(observation, point: point, normal: unitNormal) {
                let distance = simd_length_squared(point - observation.point)
                if distance < localDistance { local = observation; localDistance = distance }
            }
            // A nearby measured representative safely seeds the small native-depth
            // patch without searching other bins. Larger distances use the full search.
            if localDistance <= 0.02 * 0.02 { return local }
        }
        let lower = coverageCell(point - SIMD3(repeating: DepthScanCoverage.matchDistance))
        let upper = coverageCell(point + SIMD3(repeating: DepthScanCoverage.matchDistance))
        var selected = local
        var nearestDistance = localDistance
        for z in lower.z...upper.z {
            for y in lower.y...upper.y {
                for x in lower.x...upper.x {
                    let key = SIMD3(x, y, z)
                    if nearest, key == localKey { continue }
                    guard let observations = retainedCells[key] else { continue }
                    for observation in observations where coverageMatches(observation, point: point, normal: unitNormal) {
                        let distance = simd_length_squared(point - observation.point)
                        if nearest ? distance < nearestDistance : selected.map({ observation.capturedAt < $0.capturedAt }) ?? true {
                            selected = observation; nearestDistance = distance
                        }
                    }
                }
            }
        }
        return selected
    }
}

/// Compact saved-depth evidence for the live camera overlay. Record a frame only after
/// its local save succeeds; the accumulator itself does not establish durability.
/// The oldest retained bins are evicted at the limit so a long scan can keep showing
/// recent work. Losing display evidence does not remove anything from the saved scan.
public struct DepthScanCoverage: Sendable {
    public static let cellSize: Float = 0.08
    public static let matchDistance: Float = 0.06
    public static let maximumSampledPixels = 8_000
    public static let maximumImageDimension = 512
    public static let maximumSamplesPerCell = 4
    public static let maximumRetainedCells = 80_000

    public let maximumCells: Int
    public var retainedCellCount: Int { cells.count }
    private var cells: [SIMD3<Int>: [CoverageObservation]] = [:]
    // A fixed-capacity insertion-order ring avoids an ever-growing eviction log.
    private var insertionOrder: [SIMD3<Int>] = []
    private var nextEviction = 0

    public init(maximumCells: Int = 60_000) {
        self.maximumCells = max(0, min(maximumCells, Self.maximumRetainedCells))
    }

    @_optimize(speed)
    public mutating func recordSavedFrame(_ frame: CaptureDepthFrame) {
        guard maximumCells > 0 else { return }
        for sample in Self.samples(from: frame) {
            let key = coverageCell(sample.point)
            let observation = CoverageObservation(point: sample.point, normal: sample.normal,
                                                  capturedAt: frame.timestampSeconds)
            if var observations = cells[key] {
                // Preserve the first measured location and time during revisits. Keeping
                // measured representatives avoids drifting a point across an unseen area.
                guard !observations.contains(where: {
                    coverageMatches($0, point: sample.point, normal: sample.normal)
                }) else { continue }
                if observations.count < Self.maximumSamplesPerCell {
                    observations.append(observation)
                } else {
                    let oldest = observations.indices.min {
                        observations[$0].capturedAt < observations[$1].capturedAt
                    } ?? 0
                    observations[oldest] = observation
                }
                cells[key] = observations
            } else {
                if insertionOrder.count < maximumCells {
                    insertionOrder.append(key)
                } else {
                    cells.removeValue(forKey: insertionOrder[nextEviction])
                    insertionOrder[nextEviction] = key
                    nextEviction = (nextEviction + 1) % maximumCells
                }
                cells[key] = [observation]
            }
        }
    }

    public func snapshot() -> DepthScanCoverageSnapshot {
        DepthScanCoverageSnapshot(cells: cells)
    }

    /// Bounded shared sampling for saved evidence and live rendering. Invalid array
    /// shapes, orientation, calibration, pose, and confidence yield no evidence.
    /// Camera intrinsics are scaled to the depth image exactly as captured; returned
    /// row/column values refer to frame.depth.width/height, before display rotation.
    @_optimize(speed)
    public static func samples(from frame: CaptureDepthFrame) -> [DepthScanCoverageSample] {
        guard let geometry = CoverageFrameGeometry(frame) else { return [] }
        let step = geometry.sampleStep
        var result: [DepthScanCoverageSample] = []
        result.reserveCapacity(min(geometry.image.valuesM.count, maximumSampledPixels))
        var visited = 0
        for row in stride(from: 1, to: geometry.image.height - 1, by: step) {
            for column in stride(from: 1, to: geometry.image.width - 1, by: step) {
                guard visited < maximumSampledPixels else { return result }
                visited += 1
                if let sample = geometry.supportedSample(column: column, row: row) { result.append(sample) }
            }
        }
        return result
    }
}

/// Shared validation and projection. Copies only array references while processing;
/// no raw depth frame is retained by an accumulator or its snapshots.
struct CoverageFrameGeometry {
    let image: CaptureDepthImage
    private let confidence: [Int]
    private let transform: simd_float4x4
    private let cameraPosition: SIMD3<Float>
    private let inverseFX: Float, inverseFY: Float, cx: Float, cy: Float
    var sampleStep: Int {
        max(1, Int(ceil(sqrt(Double(image.valuesM.count) / Double(DepthScanCoverage.maximumSampledPixels)))))
    }

    @_optimize(speed)
    init?(_ frame: CaptureDepthFrame) {
        let image = frame.depth, camera = frame.camera
        let count = image.width.multipliedReportingOverflow(by: image.height)
        let cameraAspect = camera.imageWidth.multipliedReportingOverflow(by: image.height)
        let depthAspect = camera.imageHeight.multipliedReportingOverflow(by: image.width)
        guard frame.timestampSeconds.isFinite, frame.timestampSeconds >= 0,
              frame.pixelOrientation == "sensor_native", validRigidTransform(frame.mapFromCamera),
              image.width >= 3, image.height >= 3,
              image.width <= DepthScanCoverage.maximumImageDimension,
              image.height <= DepthScanCoverage.maximumImageDimension, !count.overflow,
              count.partialValue == image.valuesM.count,
              camera.imageWidth > 0, camera.imageHeight > 0,
              [camera.fx, camera.fy, camera.cx, camera.cy].allSatisfy(\.isFinite),
              camera.fx > 0, camera.fy > 0,
              camera.cx >= 0, camera.cx < Float(camera.imageWidth),
              camera.cy >= 0, camera.cy < Float(camera.imageHeight),
              !cameraAspect.overflow, !depthAspect.overflow,
              cameraAspect.partialValue == depthAspect.partialValue,
              let confidence = image.confidence, confidence.count == count.partialValue else { return nil }
        let pose = frame.mapFromCamera
        transform = simd_float4x4(columns: (SIMD4(pose[0], pose[1], pose[2], pose[3]),
                                          SIMD4(pose[4], pose[5], pose[6], pose[7]),
                                          SIMD4(pose[8], pose[9], pose[10], pose[11]),
                                          SIMD4(pose[12], pose[13], pose[14], pose[15])))
        let scaleX = Float(image.width) / Float(camera.imageWidth)
        let scaleY = Float(image.height) / Float(camera.imageHeight)
        let fx = camera.fx * scaleX, fy = camera.fy * scaleY
        inverseFX = 1 / fx; inverseFY = 1 / fy
        cx = camera.cx * scaleX; cy = camera.cy * scaleY
        guard fx.isFinite, fy.isFinite, fx > 0, fy > 0,
              inverseFX.isFinite, inverseFY.isFinite else { return nil }
        cameraPosition = SIMD3(pose[12], pose[13], pose[14])
        guard coveragePointIsValid(cameraPosition) else { return nil }
        self.image = image; self.confidence = confidence
    }

    @_transparent
    @_optimize(speed)
    private func worldPoint(column: Int, row: Int, depth: Float) -> SIMD3<Float> {
        let point = transform * SIMD4((Float(column) - cx) * depth * inverseFX,
                                      -(Float(row) - cy) * depth * inverseFY, -depth, 1)
        return SIMD3(point.x, point.y, point.z)
    }

    @_optimize(speed)
    func supportedSample(column: Int, row: Int) -> DepthScanCoverageSample? {
        let width = image.width, height = image.height
        guard column > 0, column < width - 1, row > 0, row < height - 1 else { return nil }
        let values = image.valuesM, confidence = self.confidence
        let index = row * width + column
        guard confidence[index] == 2, let depth = values[index],
              depth.isFinite, (0.2...5).contains(depth) else { return nil }
        let tolerance = min(Float(0.05), 0.015 + depth * 0.01)
        // Explicit cardinal/diagonal checks keep this per-pixel loop inexpensive
        // in Debug and never connect across a confidence hole or depth boundary.
        guard coverageNeighborSupported(index - 1, depth: depth, tolerance: tolerance, values: values, confidence: confidence),
              coverageNeighborSupported(index + 1, depth: depth, tolerance: tolerance, values: values, confidence: confidence),
              coverageNeighborSupported(index - width, depth: depth, tolerance: tolerance, values: values, confidence: confidence),
              coverageNeighborSupported(index + width, depth: depth, tolerance: tolerance, values: values, confidence: confidence) else { return nil }
        let diagonal =
            (coverageNeighborSupported(index - width - 1, depth: depth, tolerance: tolerance, values: values, confidence: confidence) ? 1 : 0)
            + (coverageNeighborSupported(index - width + 1, depth: depth, tolerance: tolerance, values: values, confidence: confidence) ? 1 : 0)
            + (coverageNeighborSupported(index + width - 1, depth: depth, tolerance: tolerance, values: values, confidence: confidence) ? 1 : 0)
            + (coverageNeighborSupported(index + width + 1, depth: depth, tolerance: tolerance, values: values, confidence: confidence) ? 1 : 0)
        guard diagonal >= 2 else { return nil }
        let point = worldPoint(column: column, row: row, depth: depth)
        guard coveragePointIsValid(point) else { return nil }
        // Opposite supported neighbors give an observed local orientation, not a
        // plane extending beyond the sample. Each force unwrap passed support above.
        let left = values[index - 1]!, right = values[index + 1]!
        let up = values[index - width]!, down = values[index + width]!
        let pixelX = Float(column) - cx, pixelY = Float(row) - cy
        let horizontal = SIMD3(((pixelX + 1) * right - (pixelX - 1) * left) * inverseFX,
                               -pixelY * (right - left) * inverseFY, left - right)
        let vertical = SIMD3(pixelX * (down - up) * inverseFX,
                             -((pixelY + 1) * down - (pixelY - 1) * up) * inverseFY, up - down)
        let cameraNormal = simd_cross(horizontal, vertical)
        let rotated = transform * SIMD4(cameraNormal.x, cameraNormal.y, cameraNormal.z, 0)
        var normal = SIMD3(rotated.x, rotated.y, rotated.z)
        let length = simd_length(normal)
        guard length.isFinite, length > 1e-6 else { return nil }
        normal /= length
        if simd_dot(normal, cameraPosition - point) < 0 { normal = -normal }
        return .init(point: point, normal: normal, column: column, row: row)
    }
}

@_transparent
@_optimize(speed)
func coveragePointIsValid(_ point: SIMD3<Float>) -> Bool {
    point.x.isFinite && point.y.isFinite && point.z.isFinite
        && abs(point.x) <= 10_000 && abs(point.y) <= 10_000 && abs(point.z) <= 10_000
}

@_transparent
@_optimize(speed)
func coverageCell(_ point: SIMD3<Float>) -> SIMD3<Int> {
    SIMD3(Int(floor(point.x / DepthScanCoverage.cellSize)),
          Int(floor(point.y / DepthScanCoverage.cellSize)),
          Int(floor(point.z / DepthScanCoverage.cellSize)))
}

@_transparent
@_optimize(speed)
func coverageMatches(_ observation: CoverageObservation, point: SIMD3<Float>,
                                normal: SIMD3<Float>?) -> Bool {
    let delta = point - observation.point
    guard simd_length_squared(delta) <= DepthScanCoverage.matchDistance * DepthScanCoverage.matchDistance,
          abs(simd_dot(delta, observation.normal)) <= 0.025 else { return false }
    return normal.map { simd_dot($0, observation.normal) >= 0.8 } ?? true
}

@_transparent
@_optimize(speed)
private func coverageNeighborSupported(_ index: Int, depth: Float, tolerance: Float,
                                       values: [Float?], confidence: [Int]) -> Bool {
    guard confidence[index] == 2, let value = values[index], value.isFinite,
          (0.2...5).contains(value) else { return false }
    return abs(value - depth) <= tolerance
}
