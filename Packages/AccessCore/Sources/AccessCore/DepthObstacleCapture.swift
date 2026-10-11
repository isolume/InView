import Foundation
import simd

/// Compact, high-confidence evidence for small obstacles that a room model may omit.
/// These are observed collision bounds, never inferred furniture categories or floor coverage.
public enum DepthObstacleEvidence {
    public static let cellSize: Float = 0.15
    public static let maximumSampledPixels = 8_000
    public static let maximumSamples = 4_096
    public static let minimumCameraHorizontalDistance: Float = 0.75

    public struct Sample: Sendable {
        public var cell: SIMD2<Int>
        public var lower: SIMD2<Float>
        public var upper: SIMD2<Float>
        public var bottom: Float
        public var top: Float
        public var floorY: Float
        /// Number of sampled pixels with compatible, high-confidence neighbors.
        public var support: Int

        public init(cell: SIMD2<Int>, lower: SIMD2<Float>, upper: SIMD2<Float>,
                    bottom: Float, top: Float, floorY: Float, support: Int) {
            self.cell = cell; self.lower = lower; self.upper = upper
            self.bottom = bottom; self.top = top; self.floorY = floorY; self.support = support
        }
    }

    /// Portable generic bounds used by the exporter. The capture contains measurements,
    /// without guessing the name, category, or unseen shape of the smaller object.
    public static func captureObject(from footprint: Footprint, id: String) -> CaptureObject? {
        guard footprint.kind == .obstacle, let bottom = footprint.bottom, let height = footprint.height,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [footprint.center.x, footprint.center.y, footprint.size.x, footprint.size.y,
               footprint.yaw, bottom, height].allSatisfy(\.isFinite),
              footprint.size.x > 0, footprint.size.y > 0, height > 0 else { return nil }
        let cosine = cos(footprint.yaw), sine = sin(footprint.yaw)
        let pose: [Float] = [cosine, 0, sine, 0, 0, 1, 0, 0, -sine, 0, cosine, 0,
                             footprint.center.x, bottom + height / 2, footprint.center.y, 1]
        guard validRigidTransform(pose) else { return nil }
        return CaptureObject(id: id, category: "unclassified_obstacle", confidence: .medium,
                             mapFromObject: pose, dimensionsM: [footprint.size.x, height, footprint.size.y])
    }

    /// Runs on copied, immutable depth values. Work is capped regardless of image resolution.
    public static func samples(from frame: CaptureDepthFrame, floorY: Float) throws -> [Sample] {
        try Task.checkCancellation()
        let image = frame.depth, camera = frame.camera
        let count = image.width.multipliedReportingOverflow(by: image.height)
        let cameraAspect = camera.imageWidth.multipliedReportingOverflow(by: image.height)
        let depthAspect = camera.imageHeight.multipliedReportingOverflow(by: image.width)
        try requireCapture(floorY.isFinite && validRigidTransform(frame.mapFromCamera)
                           && frame.timestampSeconds.isFinite && frame.timestampSeconds >= 0
                           && frame.pixelOrientation == "sensor_native"
                           && image.width > 0 && image.height > 0 && !count.overflow
                           && count.partialValue == image.valuesM.count
                           && camera.imageWidth > 0 && camera.imageHeight > 0
                           && [camera.fx, camera.fy, camera.cx, camera.cy].allSatisfy(\.isFinite)
                           && camera.fx > 0 && camera.fy > 0
                           && !cameraAspect.overflow && !depthAspect.overflow
                           && cameraAspect.partialValue == depthAspect.partialValue
                           && (image.confidence == nil || image.confidence?.count == count.partialValue),
                           "The depth scan has invalid measurements.")
        guard let confidence = image.confidence else { return [] }
        let step = max(1, (count.partialValue - 1) / maximumSampledPixels + 1)
        let pose = frame.mapFromCamera
        let transform = simd_float4x4(columns: (SIMD4(pose[0], pose[1], pose[2], pose[3]),
                                               SIMD4(pose[4], pose[5], pose[6], pose[7]),
                                               SIMD4(pose[8], pose[9], pose[10], pose[11]),
                                               SIMD4(pose[12], pose[13], pose[14], pose[15])))
        let scaleX = Float(image.width) / Float(camera.imageWidth)
        let scaleY = Float(image.height) / Float(camera.imageHeight)
        let fx = camera.fx * scaleX, fy = camera.fy * scaleY
        let cx = camera.cx * scaleX, cy = camera.cy * scaleY
        func worldPoint(column: Int, row: Int, depth: Float) -> SIMD3<Float> {
            let point = transform * SIMD4((Float(column) - cx) * depth / fx,
                                          -(Float(row) - cy) * depth / fy, -depth, 1)
            return SIMD3(point.x, point.y, point.z)
        }
        let cameraPosition = SIMD3(pose[12], pose[13], pose[14])
        var cells: [SIMD2<Int>: Sample] = [:]
        var visited = 0
        for index in stride(from: 0, to: count.partialValue, by: step) {
            if visited % 256 == 0 { try Task.checkCancellation() }
            visited += 1
            guard confidence[index] == 2, let depth = image.valuesM[index],
                  depth.isFinite, (0.5...4).contains(depth) else { continue }
            let column = index % image.width, row = index / image.width
            // Isolated returns and depth edges do not become obstacles. Require support on
            // cardinal directions too, so alternating discontinuities cannot pass diagonally.
            var neighbors = 0, cardinal = 0
            var horizontalNeighbor: SIMD3<Float>?, verticalNeighbor: SIMD3<Float>?
            let tolerance = min(Float(0.1), 0.03 + depth * 0.02)
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let x = column + dx, y = row + dy
                    guard (0..<image.width).contains(x), (0..<image.height).contains(y) else { continue }
                    let other = y * image.width + x
                    guard confidence[other] == 2, let value = image.valuesM[other], value.isFinite,
                          abs(value - depth) <= tolerance else { continue }
                    neighbors += 1
                    if dx == 0 || dy == 0 {
                        cardinal += 1
                        if dy == 0 { horizontalNeighbor = worldPoint(column: x, row: y, depth: value) }
                        if dx == 0 { verticalNeighbor = worldPoint(column: x, row: y, depth: value) }
                    }
                }
            }
            guard neighbors >= 4, cardinal >= 2,
                  let horizontalNeighbor, let verticalNeighbor else { continue }
            let world = worldPoint(column: column, row: row, depth: depth)
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
                  abs(world.x) <= 10_000, abs(world.y) <= 10_000, abs(world.z) <= 10_000,
                  simd_distance(world, cameraPosition) <= 4,
                  (0.08...0.75).contains(world.y - floorY) else { continue }
            // Smooth horizontal and gently sloped surfaces are floor/ramp evidence, not
            // clutter. Detect the supported side geometry of an object instead of its top.
            let normal = simd_cross(horizontalNeighbor - world, verticalNeighbor - world)
            guard simd_length(normal) > 1e-6, abs(simd_normalize(normal).y) <= 0.8 else { continue }
            let point = SIMD2(world.x, world.z)
            guard simd_distance(point, SIMD2(cameraPosition.x, cameraPosition.z)) >= minimumCameraHorizontalDistance else { continue }
            let cell = SIMD2(Int(floor(point.x / cellSize)), Int(floor(point.y / cellSize)))
            if var sample = cells[cell] {
                sample.lower = simd_min(sample.lower, point)
                sample.upper = simd_max(sample.upper, point)
                sample.bottom = min(sample.bottom, world.y); sample.top = max(sample.top, world.y)
                sample.support += 1
                cells[cell] = sample
            } else if cells.count < maximumSamples {
                cells[cell] = Sample(cell: cell, lower: point, upper: point,
                                     bottom: world.y, top: world.y, floorY: floorY, support: 1)
            }
        }
        try Task.checkCancellation()
        return cells.sorted { cellLess($0.key, $1.key) }.map(\.value)
    }

    fileprivate static func cellLess(_ a: SIMD2<Int>, _ b: SIMD2<Int>) -> Bool {
        a.x == b.x ? a.y < b.y : a.x < b.x
    }
}

/// Retains only compact static collision evidence, independently of archived depth keyframes.
public struct DepthObstacleAccumulator: Sendable {
    public let maximumCells: Int
    public let maximumClusters: Int
    private struct Key: Hashable, Sendable {
        var cell: SIMD2<Int>
        var level: Int
    }
    private struct Observation: Sendable {
        var pending: DepthObstacleEvidence.Sample
        var first: DepthObstacleEvidence.Sample
        var timestamp: TimeInterval
        var consistentObservations: Int = 1
        var confirmed: DepthObstacleEvidence.Sample?
    }
    private var cells: [Key: Observation] = [:]
    private var lastTimestamp: TimeInterval?
    public var retainedCellCount: Int { cells.count }

    public init(maximumCells: Int = 4_096, maximumClusters: Int = 128) {
        self.maximumCells = max(0, min(maximumCells, 4_096))
        self.maximumClusters = max(0, min(maximumClusters, 128))
    }

    public mutating func observe(_ samples: [DepthObstacleEvidence.Sample], timestamp: TimeInterval) {
        guard timestamp.isFinite, timestamp >= 0, lastTimestamp.map({ timestamp > $0 }) ?? true else { return }
        lastTimestamp = timestamp
        // Stale single-frame candidates cannot exhaust storage as a scan continues.
        cells = cells.filter { $0.value.confirmed != nil || timestamp - $0.value.timestamp <= 6 }
        var seen = Set<Key>()
        for sample in samples.prefix(DepthObstacleEvidence.maximumSamples) {
            guard valid(sample) else { continue }
            let level = Int(sample.floorY.rounded())
            let key = (-1...1).map { Key(cell: sample.cell, level: level + $0) }.first {
                guard let previous = cells[$0] else { return false }
                return abs(previous.pending.floorY - sample.floorY) <= 0.15
            } ?? Key(cell: sample.cell, level: level)
            guard seen.insert(key).inserted else { continue }
            if var observation = cells[key] {
                guard timestamp - observation.timestamp >= 0.5 else { continue }
                if timestamp - observation.timestamp <= 6,
                   spatiallyConsistent(observation.pending, sample),
                   spatiallyConsistent(observation.first, sample) {
                    observation.consistentObservations = min(3, observation.consistentObservations + 1)
                    if observation.consistentObservations >= 3 {
                        // Each frame must independently measure a supported vertical side.
                        // Retain the latest bounds instead of widening them with older noise.
                        observation.confirmed = sample
                    }
                } else {
                    observation.consistentObservations = 1
                    observation.confirmed = nil
                    observation.first = sample
                }
                observation.pending = sample; observation.timestamp = timestamp
                cells[key] = observation
            } else if cells.count < maximumCells {
                cells[key] = Observation(pending: sample, first: sample, timestamp: timestamp)
            }
        }
    }

    /// Adjacent confirmed cells form generic bounds. A real vertical span is required, so a
    /// slightly misestimated floor or a flat top alone cannot become a phantom obstacle.
    public func snapshot() -> [Footprint] {
        let confirmed = cells.compactMapValues(\.confirmed)
        var remaining = Set(confirmed.keys)
        let ordered = remaining.sorted {
            $0.level == $1.level ? DepthObstacleEvidence.cellLess($0.cell, $1.cell) : $0.level < $1.level
        }
        var result: [Footprint] = []
        for seed in ordered where remaining.contains(seed) {
            guard result.count < maximumClusters else { break }
            remaining.remove(seed)
            var queue = [seed], cursor = 0
            var members: [DepthObstacleEvidence.Sample] = []
            while cursor < queue.count {
                let key = queue[cursor]; cursor += 1
                guard let sample = confirmed[key] else { continue }
                members.append(sample)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        for level in (key.level - 1)...(key.level + 1) {
                            let next = Key(cell: key.cell &+ SIMD2(dx, dy), level: level)
                            guard let neighbor = confirmed[next], abs(neighbor.floorY - sample.floorY) <= 0.15,
                                  abs(neighbor.bottom - sample.bottom) <= 0.2,
                                  remaining.remove(next) != nil else { continue }
                            queue.append(next)
                        }
                    }
                }
            }
            guard let first = members.first else { continue }
            let lower = members.reduce(first.lower) { simd_min($0, $1.lower) }
            let upper = members.reduce(first.upper) { simd_max($0, $1.upper) }
            let bottom = members.map(\.bottom).min()!, top = members.map(\.top).max()!
            let size = upper - lower
            guard top - bottom >= 0.06, top - bottom <= 0.7,
                  top - first.floorY >= 0.1,
                  max(size.x, size.y) >= 0.08, size.x <= 2, size.y <= 2,
                  members.reduce(0, { $0 + $1.support }) >= 4 else { continue }
            result.append(Footprint(kind: .obstacle, center: (lower + upper) / 2,
                                    size: simd_max(size, SIMD2(repeating: 0.1)), yaw: 0,
                                    bottom: bottom, height: top - bottom))
        }
        return result
    }

    private func valid(_ sample: DepthObstacleEvidence.Sample) -> Bool {
        let values = [sample.lower.x, sample.lower.y, sample.upper.x, sample.upper.y,
                      sample.bottom, sample.top, sample.floorY]
        guard values.allSatisfy(\.isFinite), values.allSatisfy({ abs($0) <= 10_000 }),
              sample.support >= 4, sample.support <= DepthObstacleEvidence.maximumSampledPixels,
              sample.lower.x <= sample.upper.x, sample.lower.y <= sample.upper.y,
              sample.top - sample.bottom >= 0.06, sample.bottom >= sample.floorY + 0.079,
              sample.top <= sample.floorY + 0.751 else { return false }
        let lower = SIMD2(Float(sample.cell.x), Float(sample.cell.y)) * DepthObstacleEvidence.cellSize
        let upper = lower + SIMD2(repeating: DepthObstacleEvidence.cellSize)
        return sample.lower.x >= lower.x - 0.001 && sample.lower.y >= lower.y - 0.001
            && sample.upper.x <= upper.x + 0.001 && sample.upper.y <= upper.y + 0.001
    }

    private func spatiallyConsistent(_ first: DepthObstacleEvidence.Sample,
                                     _ second: DepthObstacleEvidence.Sample) -> Bool {
        let firstCenter = (first.lower + first.upper) / 2
        let secondCenter = (second.lower + second.upper) / 2
        let firstSize = first.upper - first.lower
        let secondSize = second.upper - second.lower
        return abs(first.floorY - second.floorY) <= 0.1
            && abs(first.top - second.top) <= 0.06
            && abs(first.bottom - second.bottom) <= 0.06
            && simd_distance(firstCenter, secondCenter) <= 0.04
            && simd_distance(firstSize, secondSize) <= 0.06
    }
}
