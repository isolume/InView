import Foundation
import simd

/// Displaying another level never changes the route planner's active floor.
public struct IndoorFloorContent: Sendable {
    public let scene: ProcessedScene?
    public let map: VenueMap?
    public let floor: IndoorSceneFloor?
    public let isRouteFloor: Bool

    public init(scene: ProcessedScene?, map: VenueMap?, selectedFloorID: String?) {
        guard let scene else {
            self.scene = scene; self.map = map; floor = nil; isRouteFloor = true
            return
        }
        let floors = IndoorSceneFloors.floors(in: scene)
        let routeElevation = map?.floorY ?? floors.first?.elevation ?? 0
        let routeFloor = floors.min { abs($0.elevation - routeElevation) < abs($1.elevation - routeElevation) }
        let selected = floors.first { $0.id == selectedFloorID } ?? routeFloor
        guard let selected else {
            self.scene = scene; self.map = map; floor = nil; isRouteFloor = true
            return
        }
        floor = selected
        isRouteFloor = selected.id == routeFloor?.id
        var selectedScene = IndoorSceneFloors.scene(scene, on: selected)
        guard let map else {
            self.scene = selectedScene; self.map = nil
            return
        }
        // Use only geometry known to belong to this display floor. The original routing map
        // can contain flattened footprints from multiple captured levels.
        var footprints = selectedScene.surfaces.compactMap(Self.footprint) + selectedScene.objects.compactMap { object in
            guard object.sourceCategory != "rug", object.mapFromObject.count == 16,
                  object.measuredDimensionsM.count == 3 else { return nil }
            return Footprint(kind: .obstacle, transform: Self.matrix(object.mapFromObject),
                             width: object.measuredDimensionsM[0], depth: object.measuredDimensionsM[2])
        }
        // Portable scenes retain floor dimensions, while the saved map retains the measured
        // outline. Keep that outline on its own level so a cutaway doesn't erase the space
        // inside the bounding rectangle of a concave room.
        footprints.append(contentsOf: map.footprints.filter { footprint in
            guard footprint.kind == .floor, let elevation = footprint.bottom, elevation.isFinite else { return false }
            return floors.min { abs($0.elevation - elevation) < abs($1.elevation - elevation) }?.id == selected.id
        })
        if isRouteFloor {
            // Camera sightings and manually added stairs may exist only in the routing map.
            // Keep them on its active floor, and give scene-backed renderers the same annotation.
            var sightingIDs: Set<UUID> = []
            var objectIDs = Set(selectedScene.objects.map(\.sourceID))
            for footprint in map.footprints where footprint.kind == .stairs {
                guard let id = footprint.id, sightingIDs.insert(id).inserted else { continue }
                footprints.append(footprint)
                let sourceID = id.uuidString
                if !objectIDs.contains(sourceID), let annotation = Self.stairsObject(footprint, sourceID: sourceID, floorY: selected.elevation) {
                    selectedScene.objects.append(annotation)
                    objectIDs.insert(sourceID)
                }
            }
        }
        self.scene = selectedScene
        self.map = VenueMap(createdAt: map.createdAt, floorY: selected.elevation,
                            footprints: footprints, points: isRouteFloor ? map.points : [],
                            geographicReference: map.geographicReference,
                            requiresMeasuredFloorCoverage: map.requiresMeasuredFloorCoverage)
    }

    private static func stairsObject(_ footprint: Footprint, sourceID: String, floorY: Float) -> SceneObject? {
        let height: Float = 0.15
        guard footprint.center.x.isFinite, footprint.center.y.isFinite, footprint.yaw.isFinite,
              footprint.size.x.isFinite, footprint.size.y.isFinite,
              footprint.size.x > 0, footprint.size.y > 0, floorY.isFinite,
              (floorY + height).isFinite else { return nil }
        let corners = footprint.corners
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let c = cos(footprint.yaw), s = sin(footprint.yaw)
        let pose: [Float] = [c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0,
                             footprint.center.x, floorY + height / 2, footprint.center.y, 1]
        let size = [footprint.size.x, height, footprint.size.y]
        let boxCorners = corners.flatMap { point in
            [[point.x, floorY, point.y], [point.x, floorY + height, point.y]]
        }
        return SceneObject(
            sourceID: sourceID, sourceCategory: "stairs", sourceConfidence: .unknown,
            modelKey: "bounds_v1", mapFromObject: pose, measuredDimensionsM: size,
            obstacleCorners: boxCorners,
            obstacleBounds: SceneBounds(
                min: [corners.map(\.x).min()!, floorY, corners.map(\.y).min()!],
                max: [corners.map(\.x).max()!, floorY + height, corners.map(\.y).max()!]
            ),
            parts: [SceneModelPart(center: [0, 0, 0], dimensionsM: size, color: "#BDBBB5")]
        )
    }

    private static func footprint(_ surface: SceneSurface) -> Footprint? {
        let kind: Footprint.Kind
        switch surface.kind {
        case "wall": kind = .wall
        case "door": kind = .door
        case "opening": kind = .opening
        default: return nil
        }
        guard surface.mapFromSurface.count == 16, surface.measuredDimensionsM.count == 3 else { return nil }
        return Footprint(kind: kind, transform: matrix(surface.mapFromSurface),
                         width: surface.measuredDimensionsM[0], depth: 0.15)
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(values[0], values[1], values[2], values[3]),
                               SIMD4(values[4], values[5], values[6], values[7]),
                               SIMD4(values[8], values[9], values[10], values[11]),
                               SIMD4(values[12], values[13], values[14], values[15])))
    }
}
