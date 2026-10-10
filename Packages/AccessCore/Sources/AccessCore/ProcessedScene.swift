import Foundation

/// Derived display geometry, kept separate from the immutable capture and routing map.
public struct ProcessedScene: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var processingVersion: Int
    public var sourceScanID: String
    public var mapID: String
    public var floorID: String
    public var coordinates: CaptureCoordinates
    public var options: SceneProcessingOptions
    public var objects: [SceneObject]
    public var surfaces: [SceneSurface]
    public var meshes: [SceneMesh]
    public var pointCloud: [ScenePoint]
    public var warnings: [String]

    public init(schemaVersion: Int = 1, processingVersion: Int = 3, sourceScanID: String,
                mapID: String, floorID: String, coordinates: CaptureCoordinates = .metersYUpRightHanded,
                options: SceneProcessingOptions = .init(), objects: [SceneObject], surfaces: [SceneSurface],
                meshes: [SceneMesh] = [], pointCloud: [ScenePoint] = [], warnings: [String] = []) {
        self.schemaVersion = schemaVersion; self.processingVersion = processingVersion
        self.sourceScanID = sourceScanID; self.mapID = mapID; self.floorID = floorID; self.coordinates = coordinates
        self.options = options; self.objects = objects; self.surfaces = surfaces
        self.meshes = meshes; self.pointCloud = pointCloud; self.warnings = warnings
    }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", processingVersion = "processing_version", sourceScanID = "source_scan_id"
        case mapID = "map_id", floorID = "floor_id", coordinates, options, objects, surfaces, meshes
        case pointCloud = "point_cloud", warnings
    }
}

public struct SceneProcessingOptions: Codable, Equatable, Sendable {
    public var minimumObjectConfidence: CaptureConfidence
    public var minimumDepthConfidence: Int?
    public var maxPoints: Int

    public init(minimumObjectConfidence: CaptureConfidence = .medium, minimumDepthConfidence: Int? = 1,
                maxPoints: Int = 20_000) {
        self.minimumObjectConfidence = minimumObjectConfidence
        self.minimumDepthConfidence = minimumDepthConfidence; self.maxPoints = maxPoints
    }
    enum CodingKeys: String, CodingKey {
        case minimumObjectConfidence = "minimum_object_confidence", minimumDepthConfidence = "minimum_depth_confidence"
        case maxPoints = "max_points"
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(minimumObjectConfidence, forKey: .minimumObjectConfidence)
        // Null explicitly allows frames without confidence; omission has a different backend default.
        if let minimumDepthConfidence { try values.encode(minimumDepthConfidence, forKey: .minimumDepthConfidence) }
        else { try values.encodeNil(forKey: .minimumDepthConfidence) }
        try values.encode(maxPoints, forKey: .maxPoints)
    }
}

public struct SceneObject: Codable, Equatable, Sendable {
    public var sourceID: String
    public var sourceCategory: String
    public var sourceConfidence: CaptureConfidence
    public var modelKey: String
    public var mapFromObject: [Float]
    public var measuredDimensionsM: [Float]
    public var obstacleCorners: [[Float]]
    public var obstacleBounds: SceneBounds
    public var parts: [SceneModelPart]
    public var modelMeshes: [SceneModelMesh]

    public init(sourceID: String, sourceCategory: String, sourceConfidence: CaptureConfidence,
                modelKey: String, mapFromObject: [Float], measuredDimensionsM: [Float],
                obstacleCorners: [[Float]], obstacleBounds: SceneBounds,
                parts: [SceneModelPart], modelMeshes: [SceneModelMesh] = []) {
        self.sourceID = sourceID; self.sourceCategory = sourceCategory; self.sourceConfidence = sourceConfidence
        self.modelKey = modelKey; self.mapFromObject = mapFromObject; self.measuredDimensionsM = measuredDimensionsM
        self.obstacleCorners = obstacleCorners; self.obstacleBounds = obstacleBounds
        self.parts = parts; self.modelMeshes = modelMeshes
    }
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", sourceCategory = "source_category", sourceConfidence = "source_confidence"
        case modelKey = "model_key", mapFromObject = "map_from_object", measuredDimensionsM = "measured_dimensions_m"
        case obstacleCorners = "obstacle_corners", obstacleBounds = "obstacle_bounds", parts, modelMeshes = "model_meshes"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        sourceCategory = try values.decode(String.self, forKey: .sourceCategory)
        sourceConfidence = try values.decode(CaptureConfidence.self, forKey: .sourceConfidence)
        modelKey = try values.decode(String.self, forKey: .modelKey)
        mapFromObject = try values.decode([Float].self, forKey: .mapFromObject)
        measuredDimensionsM = try values.decode([Float].self, forKey: .measuredDimensionsM)
        obstacleCorners = try values.decode([[Float]].self, forKey: .obstacleCorners)
        obstacleBounds = try values.decode(SceneBounds.self, forKey: .obstacleBounds)
        parts = try values.decode([SceneModelPart].self, forKey: .parts)
        modelMeshes = try values.decodeIfPresent([SceneModelMesh].self, forKey: .modelMeshes) ?? []
    }
}

public struct SceneModelPart: Codable, Equatable, Sendable {
    public var center: [Float]
    public var dimensionsM: [Float]
    public var color: String
    public init(center: [Float], dimensionsM: [Float], color: String) {
        self.center = center; self.dimensionsM = dimensionsM; self.color = color
    }
    enum CodingKeys: String, CodingKey { case center, dimensionsM = "dimensions_m", color }
}

public struct SceneModelMesh: Codable, Equatable, Sendable {
    public var name: String
    public var vertices: [[Float]]
    public var normals: [[Float]]
    public var triangles: [[Int]]
    public var color: String
    public init(name: String, vertices: [[Float]], normals: [[Float]], triangles: [[Int]], color: String) {
        self.name = name; self.vertices = vertices; self.normals = normals; self.triangles = triangles; self.color = color
    }
}

public struct SceneBounds: Codable, Equatable, Sendable {
    public var min: [Float]
    public var max: [Float]
    public init(min: [Float], max: [Float]) { self.min = min; self.max = max }
}

public struct SceneSurface: Codable, Equatable, Sendable {
    public var sourceID: String
    public var kind: String
    public var mapFromSurface: [Float]
    public var measuredDimensionsM: [Float]
    public var renderDimensionsM: [Float]
    public var color: String
    /// Original measured outline in surface-local coordinates, retained separately from display thickness.
    public var polygonCorners: [[Float]]?
    public init(sourceID: String, kind: String, mapFromSurface: [Float], measuredDimensionsM: [Float],
                renderDimensionsM: [Float], color: String, polygonCorners: [[Float]]? = nil) {
        self.sourceID = sourceID; self.kind = kind; self.mapFromSurface = mapFromSurface
        self.measuredDimensionsM = measuredDimensionsM; self.renderDimensionsM = renderDimensionsM; self.color = color
        self.polygonCorners = polygonCorners
    }
    enum CodingKeys: String, CodingKey {
        case sourceID = "source_id", kind, mapFromSurface = "map_from_surface"
        case measuredDimensionsM = "measured_dimensions_m", renderDimensionsM = "render_dimensions_m", color
        case polygonCorners = "polygon_corners"
    }
}

public struct SceneMesh: Codable, Equatable, Sendable {
    public var sourceID: String
    public var vertices: [[Float]]
    public var triangles: [[Int]]
    public var classifications: [String]?
    public init(sourceID: String, vertices: [[Float]], triangles: [[Int]], classifications: [String]? = nil) {
        self.sourceID = sourceID; self.vertices = vertices; self.triangles = triangles; self.classifications = classifications
    }
    enum CodingKeys: String, CodingKey { case sourceID = "source_id", vertices, triangles, classifications }
}

public struct ScenePoint: Codable, Equatable, Sendable {
    public var sourceFrameID: String
    public var position: [Float]
    public var confidence: Int?
    public init(sourceFrameID: String, position: [Float], confidence: Int? = nil) {
        self.sourceFrameID = sourceFrameID; self.position = position; self.confidence = confidence
    }
    enum CodingKeys: String, CodingKey { case sourceFrameID = "source_frame_id", position, confidence }
}

public enum SceneValidationError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

extension ProcessedScene {
    /// Validates before native renderers index vectors, build geometry, or use the result for bounds.
    public func validate(expectedScanID: String? = nil, source: CaptureBundle? = nil) throws {
        if let source { try source.validate() }
        func require(_ condition: Bool, _ message: String = "The backend returned invalid scene geometry.") throws {
            if !condition { throw SceneValidationError.invalid(message) }
        }
        func color(_ value: String) -> Bool {
            value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isHexDigit }
        }
        try require(schemaVersion == 1 && (1...3).contains(processingVersion), "This scene format is not supported.")
        try require(!sourceScanID.isEmpty && !mapID.isEmpty && !floorID.isEmpty
                    && coordinates == .metersYUpRightHanded, "The scene uses unsupported coordinates.")
        if let expectedScanID { try require(sourceScanID == expectedScanID, "The backend returned a different capture.") }
        try require((1...100_000).contains(options.maxPoints)
                    && (options.minimumDepthConfidence == nil || (0...2).contains(options.minimumDepthConfidence!)))
        for ids in [objects.map(\.sourceID), surfaces.map(\.sourceID), meshes.map(\.sourceID)] {
            try require(ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count)
        }
        for object in objects {
            try require(validRigidTransform(object.mapFromObject)
                        && validVector(object.measuredDimensionsM) && object.measuredDimensionsM.allSatisfy { $0 > 0 }
                        && object.obstacleCorners.count == 8 && object.obstacleCorners.allSatisfy(validVector)
                        && validVector(object.obstacleBounds.min) && validVector(object.obstacleBounds.max)
                        && zip(object.obstacleBounds.min, object.obstacleBounds.max).allSatisfy { $0 <= $1 }
                        && !object.sourceCategory.isEmpty && !object.modelKey.isEmpty)
            for part in object.parts {
                try require(validVector(part.center) && validVector(part.dimensionsM)
                            && part.dimensionsM.allSatisfy { $0 > 0 } && color(part.color))
            }
            for mesh in object.modelMeshes {
                try require(!mesh.vertices.isEmpty && mesh.vertices.allSatisfy(validVector)
                            && mesh.normals.count == mesh.vertices.count && mesh.normals.allSatisfy(validVector)
                            && !mesh.triangles.isEmpty && validTriangles(mesh.triangles, count: mesh.vertices.count)
                            && color(mesh.color))
            }
            try require(!object.parts.isEmpty || !object.modelMeshes.isEmpty)
        }
        for surface in surfaces {
            try require(validRigidTransform(surface.mapFromSurface) && !surface.kind.isEmpty
                        && validVector(surface.measuredDimensionsM) && surface.measuredDimensionsM.allSatisfy { $0 >= 0 }
                        && surface.measuredDimensionsM.filter { $0 > 0 }.count >= 2
                        && validVector(surface.renderDimensionsM) && surface.renderDimensionsM.allSatisfy { $0 > 0 }
                        && color(surface.color))
            if let polygon = surface.polygonCorners { try require(validSurfacePolygon(polygon)) }
        }
        for mesh in meshes {
            try require(!mesh.vertices.isEmpty && mesh.vertices.allSatisfy(validVector)
                        && validTriangles(mesh.triangles, count: mesh.vertices.count)
                        && (mesh.classifications == nil || mesh.classifications?.count == mesh.triangles.count))
        }
        try require(pointCloud.count <= options.maxPoints && pointCloud.allSatisfy {
            !$0.sourceFrameID.isEmpty && validVector($0.position) && ($0.confidence == nil || (0...2).contains($0.confidence!))
        })
        if let source {
            try require(sourceScanID == source.id && mapID == source.mapID && floorID == source.floorID,
                        "The backend returned a different capture.")
            try require(Set(objects.map(\.sourceID)) == Set(source.objects.map(\.id))
                        && Set(surfaces.map(\.sourceID)) == Set(source.surfaces.map(\.id))
                        && Set(meshes.map(\.sourceID)) == Set(source.meshes.map(\.id)), "The scene does not match the capture.")
            let frameIDs = Set(source.frames.map(\.id))
            try require(pointCloud.allSatisfy { frameIDs.contains($0.sourceFrameID) }, "The scene contains an unknown frame.")
            let inputObjects = Dictionary(uniqueKeysWithValues: source.objects.map { ($0.id, $0) })
            for object in objects {
                let original = inputObjects[object.sourceID]!
                try require(object.sourceCategory == original.category && object.sourceConfidence == original.confidence
                            && object.mapFromObject == original.mapFromObject
                            && object.measuredDimensionsM == original.dimensionsM, "The scene changed a captured object's measurements.")
            }
            let inputSurfaces = Dictionary(uniqueKeysWithValues: source.surfaces.map { ($0.id, $0) })
            for surface in surfaces {
                let original = inputSurfaces[surface.sourceID]!
                try require(surface.kind == original.kind && surface.mapFromSurface == original.mapFromSurface
                            && surface.measuredDimensionsM == original.dimensionsM
                            && surface.polygonCorners == original.polygonCorners,
                            "The scene changed a captured surface's measurements.")
            }
        }
    }
}
