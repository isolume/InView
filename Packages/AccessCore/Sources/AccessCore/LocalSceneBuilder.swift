import Foundation

/// Builds a simplified display scene on the device, in the capture's original AR coordinates.
public enum LocalSceneBuilder {
    public static func make(from capture: CaptureBundle, includeDepthPoints: Bool = true) throws -> ProcessedScene {
        try Task.checkCancellation()
        try capture.validate()
        let options = SceneProcessingOptions()
        var warnings: [String] = []
        let objects = try capture.objects.map { object in
            try Task.checkCancellation()
            let key = modelKey(for: object)
            let displayMeshes = try FurnitureModelCatalog.meshes(for: key, dimensions: object.dimensionsM)
            let corners: [[Float]] = try (0..<8).map { (corner: Int) -> [Float] in
                let local: [Float] = (0..<3).map { (axis: Int) -> Float in
                    let sign: Float = corner & (1 << axis) == 0 ? -0.5 : 0.5
                    return object.dimensionsM[axis] * sign
                }
                return try mapPoint(local, using: object.mapFromObject)
            }
            return SceneObject(
                sourceID: object.id,
                sourceCategory: object.category,
                sourceConfidence: object.confidence,
                modelKey: key,
                mapFromObject: object.mapFromObject,
                measuredDimensionsM: object.dimensionsM,
                obstacleCorners: corners,
                obstacleBounds: SceneBounds(
                    min: (0..<3).map { axis in corners.map { $0[axis] }.min()! },
                    max: (0..<3).map { axis in corners.map { $0[axis] }.max()! }
                ),
                parts: displayMeshes.isEmpty ? parts(for: key, dimensions: object.dimensionsM)
                    : FurnitureModelCatalog.fallbackParts(for: displayMeshes),
                modelMeshes: displayMeshes
            )
        }
        if objects.contains(where: { $0.modelKey == "bounds_v1" }) {
            warnings.append("Some items are shown using their measured shape.")
        }
        let surfaces = capture.surfaces.map { surface in
            SceneSurface(
                sourceID: surface.id,
                kind: surface.kind,
                mapFromSurface: surface.mapFromSurface,
                measuredDimensionsM: surface.dimensionsM,
                renderDimensionsM: surface.dimensionsM.map { $0 == 0 ? 0.025 : $0 },
                color: surface.kind == "floor" ? "#EEEDE9" : "#E0DFDA",
                polygonCorners: surface.polygonCorners
            )
        }
        let meshes = try capture.meshes.map { mesh in
            try Task.checkCancellation()
            return SceneMesh(sourceID: mesh.id,
                      vertices: try mesh.vertices.map { try mapPoint($0, using: mesh.mapFromAnchor) },
                      triangles: mesh.triangles, classifications: mesh.classifications, colors: mesh.colors)
        }
        var totalSamples = 0
        for frame in capture.frames where includeDepthPoints {
            let sum = totalSamples.addingReportingOverflow(frame.depth.valuesM.count)
            guard !sum.overflow else { throw invalidMeasurements() }
            totalSamples = sum.partialValue
        }
        let stride = totalSamples == 0 ? 1 : (totalSamples - 1) / options.maxPoints + 1
        var sampleIndex = 0
        var points: [ScenePoint] = []
        for frame in capture.frames where includeDepthPoints {
            try Task.checkCancellation()
            if frame.depth.confidence == nil {
                warnings.append("Depth samples without a confidence measurement were left out.")
            }
            for (index, depth) in frame.depth.valuesM.enumerated() {
                if index % 4096 == 0 { try Task.checkCancellation() }
                let take = sampleIndex % stride == 0
                sampleIndex += 1
                guard take, let depth, depth > 0,
                      let confidence = frame.depth.confidence?[index], confidence >= 1 else { continue }
                let camera = frame.camera
                let u = Double(index % frame.depth.width) * Double(camera.imageWidth) / Double(frame.depth.width)
                let v = Double(index / frame.depth.width) * Double(camera.imageHeight) / Double(frame.depth.height)
                let sensorPoint = [
                    (u - Double(camera.cx)) * Double(depth) / Double(camera.fx),
                    -(v - Double(camera.cy)) * Double(depth) / Double(camera.fy),
                    -Double(depth),
                ]
                points.append(ScenePoint(sourceFrameID: frame.id,
                                         position: try mapPoint(sensorPoint, using: frame.mapFromCamera),
                                         confidence: confidence))
            }
        }
        let scene = ProcessedScene(sourceScanID: capture.id, mapID: capture.mapID, floorID: capture.floorID,
                                   coordinates: capture.coordinates, options: options,
                                   objects: objects, surfaces: surfaces, meshes: meshes,
                                   pointCloud: points, warnings: Array(Set(warnings)).sorted())
        try scene.validate(source: capture)
        try Task.checkCancellation()
        return scene
    }

    private static func modelKey(for object: CaptureObject) -> String {
        guard object.confidence == .medium || object.confidence == .high else { return "bounds_v1" }
        if let key = FurnitureModelCatalog.modelKey(category: object.category, dimensions: object.dimensionsM) { return key }
        switch object.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chair": return "chair_v2"
        case "sofa": return "sofa_v2"
        case "table": return "table_v2"
        case "bed": return "bed_v2"
        case "storage", "cabinet": return "storage_v2"
        case "sink": return "sink_v2"
        default: return "bounds_v1"
        }
    }

    private static func parts(for key: String, dimensions: [Float]) -> [SceneModelPart] {
        var result: [SceneModelPart] = []
        func add(_ center: [Float], _ size: [Float], color: String = "#D1D0CB") {
            result.append(SceneModelPart(center: zip(center, dimensions).map(*),
                                         dimensionsM: zip(size, dimensions).map(*), color: color))
        }
        switch key {
        case "chair_v2":
            add([0, -0.02, 0], [1, 0.13, 0.95])
            add([0, 0.225, 0.425], [1, 0.55, 0.15])
            for x: Float in [-0.4, 0.4] {
                for z: Float in [-0.375, 0.375] {
                    add([x, -0.26, z], [0.1, 0.48, 0.1], color: "#B5B4AF")
                }
            }
        case "sofa_v2":
            add([0, -0.25, 0], [1, 0.28, 1])
            add([0, -0.02, -0.08], [0.74, 0.18, 0.73], color: "#DDDDD7")
            add([0, 0.24, 0.4], [1, 0.52, 0.2])
            for x: Float in [-0.435, 0.435] { add([x, 0.01, -0.06], [0.13, 0.45, 0.88]) }
            add([0, -0.44, 0], [0.85, 0.12, 0.8], color: "#B5B4AF")
        case "table_v2":
            add([0, 0.45, 0], [1, 0.1, 1], color: "#DDDDD7")
            for x: Float in [-0.4, 0.4] {
                for z: Float in [-0.4, 0.4] { add([x, -0.05, z], [0.1, 0.9, 0.1], color: "#B5B4AF") }
            }
        case "bed_v2":
            add([0, -0.1, 0], [1, 0.8, 1], color: "#DDDDD7")
            add([0, 0.05, 0.44], [1, 0.9, 0.12])
        default:
            add([0, 0, 0], [1, 1, 1])
        }
        return result
    }

    private static func mapPoint(_ point: [Float], using matrix: [Float]) throws -> [Float] {
        try mapPoint(point.map(Double.init), using: matrix)
    }

    private static func mapPoint(_ point: [Double], using matrix: [Float]) throws -> [Float] {
        let x = Double(matrix[0]) * point[0] + Double(matrix[4]) * point[1]
            + Double(matrix[8]) * point[2] + Double(matrix[12])
        let y = Double(matrix[1]) * point[0] + Double(matrix[5]) * point[1]
            + Double(matrix[9]) * point[2] + Double(matrix[13])
        let z = Double(matrix[2]) * point[0] + Double(matrix[6]) * point[1]
            + Double(matrix[10]) * point[2] + Double(matrix[14])
        let result = [Float(x), Float(y), Float(z)]
        guard result.allSatisfy({ $0.isFinite }) else { throw invalidMeasurements() }
        return result
    }

    private static func invalidMeasurements() -> SceneValidationError {
        .invalid("The scan contains measurements that could not be displayed.")
    }
}
