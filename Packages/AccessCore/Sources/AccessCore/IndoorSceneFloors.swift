import Foundation

public struct IndoorSceneFloor: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// Height in the original scan's meter-based world coordinates.
    public var elevation: Float

    public init(id: String, title: String, elevation: Float) {
        self.id = id
        self.title = title
        self.elevation = elevation
    }
}

/// Derives display levels without changing the captured geometry or its AR coordinate frame.
public enum IndoorSceneFloors {
    public static func floors(in scene: ProcessedScene) -> [IndoorSceneFloor] {
        let measured = scene.surfaces.compactMap { surface -> FloorMeasurement? in
            guard surface.kind == "floor", let elevation = floorElevation(surface) else { return nil }
            let dimensions = surface.measuredDimensionsM.sorted(by: >)
            return FloorMeasurement(elevation: elevation, area: Double(dimensions[0]) * Double(dimensions[1]))
        }.sorted { $0.elevation < $1.elevation }

        // Group the small height differences between rooms before deciding which are distinct stories.
        var clusters: [[FloorMeasurement]] = []
        for measurement in measured {
            if let first = clusters.last?.first, measurement.elevation - first.elevation <= roomTolerance {
                clusters[clusters.count - 1].append(measurement)
            } else {
                clusters.append([measurement])
            }
        }
        var levels: [[FloorMeasurement]] = []
        for cluster in clusters {
            if let previous = levels.last,
               representative(cluster) - representative(previous) < minimumLevelSeparation {
                levels[levels.count - 1].append(contentsOf: cluster)
            } else {
                levels.append(cluster)
            }
        }
        return levels.enumerated().map { index, measurements in
            IndoorSceneFloor(
                id: "\(scene.floorID)-level-\(index + 1)",
                title: "Floor \(index + 1)",
                elevation: representative(measurements)
            )
        }
    }

    /// Returns a display-only scene for the selected floor, optionally retaining levels below it.
    /// Original surface footprints, dimensions, and AR transforms are kept exactly as captured.
    public static func scene(
        _ scene: ProcessedScene,
        on floor: IndoorSceneFloor,
        includeLowerFloors: Bool = false
    ) -> ProcessedScene {
        let levels = floors(in: scene)
        var result = scene
        // Raw reconstruction can contain ceilings and geometry shared across stories. Leave it out
        // of the cutaway instead of allowing an unclassified mesh to cover the selected interior.
        result.meshes = []
        result.pointCloud = []
        guard let selectedIndex = levels.firstIndex(where: { $0.id == floor.id }) else {
            result.objects = []
            result.surfaces = []
            return result
        }
        result.floorID = levels[selectedIndex].id

        func isVisible(_ elevation: Float) -> Bool {
            guard elevation.isFinite,
                  elevation >= levels[0].elevation - roomTolerance,
                  elevation < levels[levels.count - 1].elevation + topLevelAllowance else { return false }
            let closest = levels.indices.min {
                abs(levels[$0].elevation - elevation) < abs(levels[$1].elevation - elevation)
            } ?? selectedIndex
            return includeLowerFloors ? closest <= selectedIndex : closest == selectedIndex
        }

        result.surfaces = scene.surfaces.filter { surface in
            if surface.kind == "floor" {
                return floorElevation(surface).map(isVisible) ?? false
            }
            // A cutaway exposes the room; a captured ceiling must not close it again.
            guard surface.kind != "ceiling", let base = baseElevation(surface) else { return false }
            return isVisible(base)
        }
        result.objects = scene.objects.filter { object in
            guard validVector(object.obstacleBounds.min), validVector(object.obstacleBounds.max),
                  zip(object.obstacleBounds.min, object.obstacleBounds.max).allSatisfy({ $0 <= $1 }) else { return false }
            return isVisible(object.obstacleBounds.min[1])
        }
        return result
    }

    private struct FloorMeasurement {
        var elevation: Float
        var area: Double
    }

    private static let roomTolerance: Float = 0.5
    private static let minimumLevelSeparation: Float = 2
    // There is no next measured floor above the top level. This bounds stray geometry while
    // retaining furniture and wall-mounted items within a normal room height.
    private static let topLevelAllowance: Float = 3

    private static func representative(_ measurements: [FloorMeasurement]) -> Float {
        // Weight measured room floors more heavily than a small landing or step.
        let totalArea = measurements.reduce(0.0) { $0 + $1.area }
        let weightedHeight = measurements.reduce(0.0) { $0 + Double($1.elevation) * $1.area }
        return Float(weightedHeight / totalArea)
    }

    private static func validSurface(_ surface: SceneSurface) -> Bool {
        validRigidTransform(surface.mapFromSurface)
            && validVector(surface.measuredDimensionsM)
            && surface.measuredDimensionsM.allSatisfy { $0 >= 0 }
            && surface.measuredDimensionsM.filter { $0 > 0 }.count >= 2
    }

    private static func floorElevation(_ surface: SceneSurface) -> Float? {
        guard validSurface(surface),
              let normalAxis = surface.measuredDimensionsM.indices.min(by: {
                  surface.measuredDimensionsM[$0] < surface.measuredDimensionsM[$1]
              }),
              abs(surface.mapFromSurface[normalAxis * 4 + 1]) >= 0.9 else { return nil }
        return surface.mapFromSurface[13]
    }

    private static func baseElevation(_ surface: SceneSurface) -> Float? {
        guard validSurface(surface) else { return nil }
        // Transform the box's extent into world Y; local Y is not always vertical in RoomPlan.
        let verticalExtent = (0..<3).reduce(0.0) {
            $0 + abs(Double(surface.mapFromSurface[$1 * 4 + 1])) * Double(surface.measuredDimensionsM[$1])
        }
        let base = Float(Double(surface.mapFromSurface[13]) - verticalExtent / 2)
        return base.isFinite ? base : nil
    }
}
