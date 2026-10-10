import Foundation
import simd

/// A 3D scene built straight from a saved map, so any map can be shown in 3D the moment it opens, with or
/// without the scan's processed capture.
///
/// Rooms RoomPlan measured at slightly different floor heights are set on the map's one floor, the way the
/// route planner treats them; windows and raised furniture keep their height above their own room's floor.
public enum VenueScene {
    public static func make(from map: VenueMap) -> ProcessedScene? {
        let floors = map.footprints.filter { $0.kind == .floor }
        /// The floor of the room a footprint belongs to. Walls and windows sit on a room's edge, so a point
        /// outside every outline belongs to the nearest one.
        func roomFloor(at point: SIMD2<Float>) -> Float {
            let outlines = floors.map { ($0, $0.polygon ?? $0.corners) }
            if let inside = outlines.first(where: { Polygon.contains(point, in: $0.1) }) { return inside.0.bottom ?? map.floorY }
            let nearest = outlines.min { distance(from: point, to: $0.1) < distance(from: point, to: $1.1) }
            return nearest?.0.bottom ?? map.floorY
        }
        func lift(_ footprint: Footprint) -> Float {
            guard let bottom = footprint.bottom else { return 0 }
            return max(0, bottom - roomFloor(at: footprint.center))
        }

        var surfaces: [CaptureSurface] = []
        var objects: [CaptureObject] = []
        var outlines: [String: [[Float]]] = [:]
        for (index, footprint) in map.footprints.enumerated() {
            let id = "\(footprint.kind.rawValue)-\(index)"
            guard footprint.size.x > 0, footprint.center.x.isFinite, footprint.center.y.isFinite else { continue }
            switch footprint.kind {
            case .floor:
                guard footprint.size.y > 0 else { continue }
                surfaces.append(CaptureSurface(id: id, kind: "floor", mapFromSurface: pose(footprint, y: map.floorY),
                                               dimensionsM: [footprint.size.x, 0, footprint.size.y]))
                if let polygon = footprint.polygon, polygon.count >= 3 {
                    outlines[id] = polygon.map { [$0.x, $0.y] }
                }
            case .wall, .door, .opening, .window:
                let height = max(0.05, footprint.height ?? defaultHeight(of: footprint.kind))
                let bottom = map.floorY + (footprint.kind == .window ? lift(footprint) : 0)
                surfaces.append(CaptureSurface(id: id, kind: footprint.kind.rawValue,
                                               mapFromSurface: pose(footprint, y: bottom + height / 2),
                                               dimensionsM: [footprint.size.x, height, max(0, footprint.size.y)]))
            case .obstacle, .stairs:
                guard footprint.size.y > 0 else { continue }
                let height = max(0.05, footprint.height ?? (footprint.kind == .stairs ? 0.6 : 0.8))
                let bottom = map.floorY + (footprint.kind == .obstacle ? lift(footprint) : 0)
                objects.append(CaptureObject(id: id, category: category(of: footprint), confidence: .high,
                                             mapFromObject: pose(footprint, y: bottom + height / 2),
                                             dimensionsM: [footprint.size.x, height, footprint.size.y]))
            }
        }
        guard !surfaces.isEmpty || !objects.isEmpty else { return nil }
        let capture = CaptureBundle(id: "venue-map", mapID: "venue-map", objects: objects, surfaces: surfaces)
        guard var scene = try? LocalSceneBuilder.make(from: capture) else { return nil }
        for index in scene.surfaces.indices {
            scene.surfaces[index].outline = outlines[scene.surfaces[index].sourceID]
        }
        return scene
    }

    private static func distance(from point: SIMD2<Float>, to outline: [SIMD2<Float>]) -> Float {
        guard let last = outline.last else { return .infinity }
        var previous = last
        var nearest = Float.infinity
        for corner in outline {
            let edge = corner - previous
            let along = simd_length_squared(edge) > 0 ? simd_clamp(simd_dot(point - previous, edge) / simd_length_squared(edge), 0, 1) : 0
            nearest = min(nearest, simd_distance(point, previous + edge * along))
            previous = corner
        }
        return nearest
    }

    /// Column-major pose: centered on the footprint at height `y`, turned by its yaw about the vertical.
    private static func pose(_ footprint: Footprint, y: Float) -> [Float] {
        let c = cos(footprint.yaw), s = sin(footprint.yaw)
        return [c, 0, s, 0,
                0, 1, 0, 0,
                -s, 0, c, 0,
                footprint.center.x, y, footprint.center.y, 1]
    }

    private static func defaultHeight(of kind: Footprint.Kind) -> Float {
        switch kind {
        case .wall: 2.4
        case .door, .opening: 2.0
        case .window: 1.2
        default: 1
        }
    }

    private static func category(of footprint: Footprint) -> String {
        if footprint.kind == .stairs { return "stairs" }
        switch footprint.furniture {
        case .appliance: return "refrigerator"
        case let furniture?: return furniture.rawValue
        case nil: return "object"
        }
    }
}
