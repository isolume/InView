import Foundation
import HeapModule
import simd

/// An outline in the scan's shared world coordinates. Preview clipping never changes the capture.
public struct ScanPreviewLine: Equatable, Sendable {
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>

    public init(start: SIMD3<Float>, end: SIMD3<Float>) {
        self.start = start
        self.end = end
    }
}

/// A measured RoomPlan surface or object, using its stable component identifier.
public struct ScanPreviewComponent: Equatable, Sendable {
    public var id: UUID
    public var lines: [ScanPreviewLine]

    public init(id: UUID, lines: [ScanPreviewLine]) {
        self.id = id
        self.lines = lines
    }
}

/// Keeps compact measurements for revisits while supplying only nearby outline geometry to the GPU.
/// Each line is split into short pieces and indexed by its extent, so a wall's far-away center cannot
/// hide a nearby end. Camera refreshes visit neighboring cells instead of the whole captured room.
public struct ScanPreviewIndex: Sendable {
    public static let cellSize: Float = 4
    public static let previewRadius: Float = 6
    public static let maximumVisibleLines = 1_536
    public static let maximumSegmentsPerComponent = 512
    public static let maximumCoordinateMagnitude: Float = 1_000_000

    private struct Cell: Hashable, Sendable {
        var x: Int
        var z: Int
    }

    private struct PieceID: Hashable, Sendable {
        var component: UUID
        var index: Int
    }

    private struct Piece: Sendable {
        var line: ScanPreviewLine
        var minimum: Cell
        var maximum: Cell
    }

    private struct StoredComponent: Sendable {
        var sourceLines: [ScanPreviewLine]
        var pieces: [Piece]
        var sortKey: String
    }

    private struct Candidate: Comparable {
        var line: ScanPreviewLine
        var distanceSquared: Double
        var componentKey: String
        var index: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.distanceSquared != rhs.distanceSquared { return lhs.distanceSquared < rhs.distanceSquared }
            if lhs.componentKey != rhs.componentKey { return lhs.componentKey < rhs.componentKey }
            return lhs.index < rhs.index
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.distanceSquared == rhs.distanceSquared && lhs.componentKey == rhs.componentKey && lhs.index == rhs.index
        }
    }

    private var components: [UUID: StoredComponent] = [:]
    private var buckets: [Cell: Set<PieceID>] = [:]

    public init() {}

    /// Replaces the latest room measurements, removing missing or invalid components. Unchanged
    /// components keep their existing index entries. Invalid coordinates and components requiring
    /// more than 512 preview pieces are omitted here; their original capture remains untouched.
    /// For repeated identifiers, the final component in the replacement is authoritative.
    public mutating func replace(with replacement: [ScanPreviewComponent]) {
        var latest: [UUID: [ScanPreviewLine]] = [:]
        for component in replacement { latest[component.id] = component.lines }
        for id in Array(components.keys) where latest[id] == nil { remove(id) }
        for (id, lines) in latest {
            if components[id]?.sourceLines == lines { continue }
            remove(id)
            guard let pieces = Self.pieces(from: lines), !pieces.isEmpty else { continue }
            components[id] = StoredComponent(sourceLines: lines, pieces: pieces, sortKey: id.uuidString)
            for (index, piece) in pieces.enumerated() {
                let key = PieceID(component: id, index: index)
                for x in piece.minimum.x...piece.maximum.x {
                    for z in piece.minimum.z...piece.maximum.z {
                        buckets[Cell(x: x, z: z), default: []].insert(key)
                    }
                }
            }
        }
    }

    /// Clips every returned line to a 6 m sphere around the camera, keeping at most the closest
    /// 1,536 pieces. Retained distant measurements never enter this result or a rendering buffer.
    public func nearbyLines(to camera: SIMD3<Float>) -> [ScanPreviewLine] {
        nearbyQuery(to: camera).lines
    }

    /// The count allows tests to verify that distant components do not add camera-refresh work.
    func nearbyQuery(to camera: SIMD3<Float>) -> (lines: [ScanPreviewLine], examinedPieceCount: Int) {
        guard Self.valid(camera),
              let minimum = Self.cell(at: camera - SIMD3(Self.previewRadius, 0, Self.previewRadius)),
              let maximum = Self.cell(at: camera + SIMD3(Self.previewRadius, 0, Self.previewRadius)) else { return ([], 0) }
        var nearest = Heap<Candidate>()
        var examined = 0
        for x in minimum.x...maximum.x {
            for z in minimum.z...maximum.z {
                guard let keys = buckets[Cell(x: x, z: z)] else { continue }
                for key in keys {
                    guard let component = components[key.component] else { continue }
                    let piece = component.pieces[key.index]
                    // A piece can touch several cells. Visit it only in the first cell shared by
                    // its bounds and this query, avoiding a growing temporary deduplication set.
                    guard x == max(piece.minimum.x, minimum.x), z == max(piece.minimum.z, minimum.z) else { continue }
                    examined += 1
                    guard let clipped = Self.clip(piece.line, to: camera) else { continue }
                    let candidate = Candidate(line: clipped.line, distanceSquared: clipped.distanceSquared,
                                              componentKey: component.sortKey, index: key.index)
                    if nearest.count < Self.maximumVisibleLines {
                        nearest.insert(candidate)
                    } else if let farthest = nearest.max, candidate < farthest {
                        _ = nearest.popMax()
                        nearest.insert(candidate)
                    }
                }
            }
        }
        var result: [ScanPreviewLine] = []
        result.reserveCapacity(nearest.count)
        while let candidate = nearest.popMin() { result.append(candidate.line) }
        return (result, examined)
    }

    private mutating func remove(_ id: UUID) {
        guard let old = components.removeValue(forKey: id) else { return }
        for (index, piece) in old.pieces.enumerated() {
            let key = PieceID(component: id, index: index)
            for x in piece.minimum.x...piece.maximum.x {
                for z in piece.minimum.z...piece.maximum.z {
                    let cell = Cell(x: x, z: z)
                    buckets[cell]?.remove(key)
                    if buckets[cell]?.isEmpty == true { buckets.removeValue(forKey: cell) }
                }
            }
        }
    }

    private static func pieces(from lines: [ScanPreviewLine]) -> [Piece]? {
        guard lines.count <= maximumSegmentsPerComponent else { return nil }
        var result: [Piece] = []
        for line in lines {
            guard valid(line.start), valid(line.end) else { return nil }
            let start = SIMD3<Double>(line.start)
            let delta = SIMD3<Double>(line.end) - start
            let length = simd_length(delta)
            guard length > 0.00001 else { continue }
            let required = ceil(length / Double(cellSize))
            guard required <= Double(maximumSegmentsPerComponent - result.count) else { return nil }
            let count = Int(required)
            for index in 0..<count {
                let a = SIMD3<Float>(start + delta * (Double(index) / Double(count)))
                let b = SIMD3<Float>(start + delta * (Double(index + 1) / Double(count)))
                guard let minimum = cell(at: simd_min(a, b)), let maximum = cell(at: simd_max(a, b)) else { return nil }
                result.append(Piece(line: ScanPreviewLine(start: a, end: b), minimum: minimum, maximum: maximum))
            }
        }
        return result
    }

    private static func clip(_ line: ScanPreviewLine, to camera: SIMD3<Float>) -> (line: ScanPreviewLine, distanceSquared: Double)? {
        // Double arithmetic avoids cancellation when an otherwise valid scan is far from origin.
        let camera = SIMD3<Double>(camera)
        let start = SIMD3<Double>(line.start)
        let delta = SIMD3<Double>(line.end) - start
        let offset = start - camera
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.0000000001 else { return nil }
        let center = -simd_dot(offset, delta) / lengthSquared
        let perpendicular = offset + delta * center
        let radiusSquared = Double(previewRadius * previewRadius)
        let remaining = radiusSquared - simd_length_squared(perpendicular)
        guard remaining >= 0 else { return nil }
        let half = sqrt(remaining / lengthSquared)
        let first = max(0, center - half), last = min(1, center + half)
        guard last > first else { return nil }
        let closest = offset + delta * min(1, max(0, center))
        return (ScanPreviewLine(start: SIMD3<Float>(start + delta * first), end: SIMD3<Float>(start + delta * last)),
                simd_length_squared(closest))
    }

    private static func valid(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
            && abs(point.x) <= maximumCoordinateMagnitude
            && abs(point.y) <= maximumCoordinateMagnitude
            && abs(point.z) <= maximumCoordinateMagnitude
    }

    private static func cell(at point: SIMD3<Float>) -> Cell? {
        guard let x = Int(exactly: floor(Double(point.x) / Double(cellSize))),
              let z = Int(exactly: floor(Double(point.z) / Double(cellSize))) else { return nil }
        return Cell(x: x, z: z)
    }
}
