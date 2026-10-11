import Foundation

/// JSON supplied by a capture provider that should survive without a custom Swift projection.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

/// Draft interchange format shared with the Rust backend; matrices are column-major.
public struct CaptureBundle: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var mapID: String
    public var floorID: String
    public var coordinates: CaptureCoordinates
    public var meshes: [CaptureMesh]
    public var frames: [CaptureDepthFrame]
    public var objects: [CaptureObject]
    public var surfaces: [CaptureSurface]
    public var metadata: JSONValue?
    public var roomplanOriginal: JSONValue?

    public init(schemaVersion: Int = 1, id: String, mapID: String, floorID: String = "ground",
                coordinates: CaptureCoordinates = .metersYUpRightHanded,
                meshes: [CaptureMesh] = [], frames: [CaptureDepthFrame] = [],
                objects: [CaptureObject] = [], surfaces: [CaptureSurface] = [],
                metadata: JSONValue? = nil, roomplanOriginal: JSONValue? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.mapID = mapID
        self.floorID = floorID
        self.coordinates = coordinates
        self.meshes = meshes
        self.frames = frames
        self.objects = objects
        self.surfaces = surfaces
        self.metadata = metadata
        self.roomplanOriginal = roomplanOriginal
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, mapID = "map_id", floorID = "floor_id"
        case coordinates, meshes, frames, objects, surfaces, metadata
        case roomplanOriginal = "roomplan_original"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        id = try values.decode(String.self, forKey: .id)
        mapID = try values.decode(String.self, forKey: .mapID)
        floorID = try values.decode(String.self, forKey: .floorID)
        coordinates = try values.decode(CaptureCoordinates.self, forKey: .coordinates)
        meshes = try values.decodeIfPresent([CaptureMesh].self, forKey: .meshes) ?? []
        frames = try values.decodeIfPresent([CaptureDepthFrame].self, forKey: .frames) ?? []
        objects = try values.decodeIfPresent([CaptureObject].self, forKey: .objects) ?? []
        surfaces = try values.decodeIfPresent([CaptureSurface].self, forKey: .surfaces) ?? []
        metadata = values.contains(.metadata) ? try values.decode(JSONValue.self, forKey: .metadata) : nil
        roomplanOriginal = values.contains(.roomplanOriginal) ? try values.decode(JSONValue.self, forKey: .roomplanOriginal) : nil
    }
}

public struct CaptureCoordinates: Codable, Equatable, Sendable {
    public var units: String
    public var upAxis: String
    public var handedness: String
    public static let metersYUpRightHanded = CaptureCoordinates(units: "meters", upAxis: "y", handedness: "right")

    public init(units: String, upAxis: String, handedness: String) {
        self.units = units; self.upAxis = upAxis; self.handedness = handedness
    }
    enum CodingKeys: String, CodingKey { case units, upAxis = "up_axis", handedness }
}

public enum CaptureConfidence: String, Codable, Sendable {
    case unknown, low, medium, high
}

public struct CaptureObject: Codable, Equatable, Sendable {
    public var id: String
    public var category: String
    public var confidence: CaptureConfidence
    public var mapFromObject: [Float]
    public var dimensionsM: [Float]

    public init(id: String, category: String, confidence: CaptureConfidence = .unknown,
                mapFromObject: [Float], dimensionsM: [Float]) {
        self.id = id; self.category = category; self.confidence = confidence
        self.mapFromObject = mapFromObject; self.dimensionsM = dimensionsM
    }
    enum CodingKeys: String, CodingKey {
        case id, category, confidence, mapFromObject = "map_from_object", dimensionsM = "dimensions_m"
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        category = try values.decode(String.self, forKey: .category)
        confidence = try values.decodeIfPresent(CaptureConfidence.self, forKey: .confidence) ?? .unknown
        mapFromObject = try values.decode([Float].self, forKey: .mapFromObject)
        dimensionsM = try values.decode([Float].self, forKey: .dimensionsM)
    }
}

public struct CaptureSurface: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var mapFromSurface: [Float]
    public var dimensionsM: [Float]
    /// Measured outline in the surface's local centered coordinates, without a repeated closing vertex.
    public var polygonCorners: [[Float]]?

    public init(id: String, kind: String, mapFromSurface: [Float], dimensionsM: [Float],
                polygonCorners: [[Float]]? = nil) {
        self.id = id; self.kind = kind; self.mapFromSurface = mapFromSurface; self.dimensionsM = dimensionsM
        self.polygonCorners = polygonCorners
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, mapFromSurface = "map_from_surface", dimensionsM = "dimensions_m"
        case polygonCorners = "polygon_corners"
    }
}

public struct CaptureMesh: Codable, Equatable, Sendable {
    public var id: String
    public var mapFromAnchor: [Float]
    public var vertices: [[Float]]
    public var triangles: [[Int]]
    public var classifications: [String]?
    /// One sRGB color per vertex, packed as 0xRRGGBB, sampled from the scan's photos.
    public var colors: [UInt32]?

    public init(id: String, mapFromAnchor: [Float], vertices: [[Float]], triangles: [[Int]],
                classifications: [String]? = nil, colors: [UInt32]? = nil) {
        self.id = id; self.mapFromAnchor = mapFromAnchor; self.vertices = vertices
        self.triangles = triangles; self.classifications = classifications; self.colors = colors
    }
    enum CodingKeys: String, CodingKey {
        case id, mapFromAnchor = "map_from_anchor", vertices, triangles, classifications
        case colors = "vertex_colors"
    }
}

public struct CaptureDepthFrame: Codable, Equatable, Sendable {
    public var id: String
    public var timestampSeconds: Double
    public var pixelOrientation: String
    public var mapFromCamera: [Float]
    public var camera: CaptureCameraCalibration
    public var depth: CaptureDepthImage
    public var colorAsset: String?

    public init(id: String, timestampSeconds: Double, pixelOrientation: String = "sensor_native",
                mapFromCamera: [Float], camera: CaptureCameraCalibration,
                depth: CaptureDepthImage, colorAsset: String? = nil) {
        self.id = id; self.timestampSeconds = timestampSeconds; self.pixelOrientation = pixelOrientation
        self.mapFromCamera = mapFromCamera; self.camera = camera; self.depth = depth; self.colorAsset = colorAsset
    }
    enum CodingKeys: String, CodingKey {
        case id, timestampSeconds = "timestamp_seconds", pixelOrientation = "pixel_orientation"
        case mapFromCamera = "map_from_camera", camera, depth, colorAsset = "color_asset"
    }
}

public struct CaptureCameraCalibration: Codable, Equatable, Sendable {
    public var imageWidth: Int
    public var imageHeight: Int
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float

    public init(imageWidth: Int, imageHeight: Int, fx: Float, fy: Float, cx: Float, cy: Float) {
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }
    enum CodingKeys: String, CodingKey { case imageWidth = "image_width", imageHeight = "image_height", fx, fy, cx, cy }
}

public struct CaptureDepthImage: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var valuesM: [Float?]
    public var confidence: [Int]?

    public init(width: Int, height: Int, valuesM: [Float?], confidence: [Int]? = nil) {
        self.width = width; self.height = height; self.valuesM = valuesM; self.confidence = confidence
    }
    enum CodingKeys: String, CodingKey { case width, height, valuesM = "values_m", confidence }
}

public enum CaptureValidationError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

extension CaptureBundle {
    /// Reject invalid array shapes before upload, so captured data cannot produce a malformed scene.
    public func validate() throws {
        try requireCapture(schemaVersion == 1, "This capture format is not supported.")
        try requireCapture(!id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           && !mapID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                           && !floorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "The capture needs an identifier.")
        try requireCapture(coordinates == .metersYUpRightHanded, "The capture uses unsupported coordinates.")
        try requireCapture(!meshes.isEmpty || !frames.isEmpty || !objects.isEmpty || !surfaces.isEmpty, "The capture is empty.")
        for ids in [meshes.map(\.id), frames.map(\.id), objects.map(\.id), surfaces.map(\.id)] {
            try requireCapture(ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                               && Set(ids).count == ids.count, "Capture identifiers must be unique.")
        }
        for object in objects {
            try requireCapture(!object.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               && validVector(object.dimensionsM) && object.dimensionsM.allSatisfy { $0 > 0 }
                               && validRigidTransform(object.mapFromObject), "An object has invalid measurements.")
        }
        for surface in surfaces {
            try requireCapture(!surface.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               && validVector(surface.dimensionsM) && surface.dimensionsM.allSatisfy { $0 >= 0 }
                               && surface.dimensionsM.filter { $0 > 0 }.count >= 2
                               && validRigidTransform(surface.mapFromSurface), "A surface has invalid measurements.")
            if let polygon = surface.polygonCorners {
                try requireCapture(validSurfacePolygon(polygon), "A surface has an invalid outline.")
            }
        }
        for mesh in meshes {
            try requireCapture(validRigidTransform(mesh.mapFromAnchor) && !mesh.vertices.isEmpty
                               && mesh.vertices.allSatisfy(validVector)
                               && validTriangles(mesh.triangles, count: mesh.vertices.count)
                               && (mesh.classifications == nil || mesh.classifications?.count == mesh.triangles.count)
                               && validVertexColors(mesh.colors, count: mesh.vertices.count),
                               "A mesh has invalid geometry.")
        }
        for frame in frames {
            let camera = frame.camera
            let depth = frame.depth
            let pixelCount = depth.width.multipliedReportingOverflow(by: depth.height)
            let cameraAspect = camera.imageWidth.multipliedReportingOverflow(by: depth.height)
            let depthAspect = camera.imageHeight.multipliedReportingOverflow(by: depth.width)
            try requireCapture(validRigidTransform(frame.mapFromCamera) && frame.timestampSeconds.isFinite
                               && frame.timestampSeconds >= 0 && frame.pixelOrientation == "sensor_native"
                               && camera.imageWidth > 0 && camera.imageHeight > 0
                               && [camera.fx, camera.fy, camera.cx, camera.cy].allSatisfy(\.isFinite)
                               && camera.fx > 0 && camera.fy > 0
                               && depth.width > 0 && depth.height > 0 && !pixelCount.overflow
                               && pixelCount.partialValue == depth.valuesM.count
                               && !cameraAspect.overflow && !depthAspect.overflow
                               && cameraAspect.partialValue == depthAspect.partialValue
                               && depth.valuesM.allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0) }
                               && (depth.confidence == nil || (depth.confidence?.count == depth.valuesM.count
                                   && depth.confidence!.allSatisfy { (0...2).contains($0) })),
                               "A depth frame has invalid measurements.")
        }
    }
}

func requireCapture(_ condition: Bool, _ message: String) throws {
    if !condition { throw CaptureValidationError.invalid(message) }
}

func validVector(_ value: [Float]) -> Bool { value.count == 3 && value.allSatisfy(\.isFinite) }

/// Accepts either local XY or XZ surface planes, including concave measured outlines.
func validSurfacePolygon(_ corners: [[Float]]) -> Bool {
    guard (3...128).contains(corners.count), corners.allSatisfy(validVector) else { return false }
    // Work relative to the first vertex so translated coordinates cannot cancel the area.
    let origin = corners[0].map(Double.init)
    var twiceArea = [Double](repeating: 0, count: 3)
    for index in corners.indices {
        let a = zip(corners[index].map(Double.init), origin).map(-)
        let b = zip(corners[(index + 1) % corners.count].map(Double.init), origin).map(-)
        twiceArea[0] += a[1] * b[2] - a[2] * b[1]
        twiceArea[1] += a[2] * b[0] - a[0] * b[2]
        twiceArea[2] += a[0] * b[1] - a[1] * b[0]
    }
    return twiceArea.allSatisfy(\.isFinite) && twiceArea.reduce(0) { $0 + $1 * $1 } > 4e-12
}

func validRigidTransform(_ matrix: [Float]) -> Bool {
    guard matrix.count == 16 && matrix.allSatisfy(\.isFinite) else { return false }
    func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= 0.0001 }
    guard near(matrix[3], 0), near(matrix[7], 0), near(matrix[11], 0), near(matrix[15], 1) else { return false }
    let x = Array(matrix[0...2]), y = Array(matrix[4...6]), z = Array(matrix[8...10])
    func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    let cross = [x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0]]
    return near(dot(x, x), 1) && near(dot(y, y), 1) && near(dot(z, z), 1)
        && near(dot(x, y), 0) && near(dot(x, z), 0) && near(dot(y, z), 0) && near(dot(cross, z), 1)
}

func validVertexColors(_ colors: [UInt32]?, count: Int) -> Bool {
    guard let colors else { return true }
    return colors.count == count && colors.allSatisfy { $0 <= 0xFF_FFFF }
}

func validTriangles(_ triangles: [[Int]], count: Int) -> Bool {
    triangles.allSatisfy { indices in
        indices.count == 3 && Set(indices).count == 3 && indices.allSatisfy { $0 >= 0 && $0 < count }
    }
}
