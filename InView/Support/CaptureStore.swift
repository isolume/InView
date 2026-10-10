import AccessCore
import ARKit
import Foundation

/// Each source scan and its derived scene have their own files. Saving a map selects its capture.
enum CaptureStore {
    private static var root: URL { URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory) }
    private static var activeURL: URL { URL.documentsDirectory.appending(path: "active-capture.json") }

    static func stage(_ bundle: CaptureBundle, rawData: Data, roomPlanData: Data) throws {
        try stageOriginals(id: bundle.id, rawData: rawData, roomPlanData: roomPlanData)
        let directory = try directory(for: bundle.id)
        try JSONEncoder().encode(bundle).write(to: directory.appending(path: "capture.json"), options: .atomic)
    }

    /// Preserves the ARKit relocalization reference next to the RoomPlan and raw capture assets,
    /// making one capture directory portable to a backend or another on-device map store.
    static func stageWorldMap(_ worldMap: ARWorldMap, id: String) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try data.write(to: try directory(for: id).appending(path: "worldmap.archive"), options: .atomic)
    }

    static func stageColorKeyframes(_ keyframes: [RawColorKeyframe], id: String) throws {
        let directory = try directory(for: id)
        for keyframe in keyframes {
            try keyframe.jpeg.write(to: directory.appending(path: keyframe.filename), options: .atomic)
        }
    }

    /// Write native LiDAR buffers as binary sidecars instead of requiring reconstruction workers to
    /// decode base64 JSON. Row strides, pixel formats, transforms, and calibration stay in the
    /// manifest/raw snapshot; these files are the exact copied ARKit bytes.
    static func stageNativeLidarAssets(_ snapshot: RawScanSnapshot, id: String) throws {
        let directory = try directory(for: id)
        for depth in snapshot.depthBuffers {
            try depth.depth.write(to: directory.appending(path: rawDepthFilename(depth.id)), options: .atomic)
            if let confidence = depth.confidence {
                try confidence.write(to: directory.appending(path: confidenceFilename(depth.id)), options: .atomic)
            }
            if let smoothed = depth.smoothedDepth {
                try smoothed.write(to: directory.appending(path: smoothedDepthFilename(depth.id)), options: .atomic)
            }
        }
        for mesh in snapshot.meshBuffers {
            try mesh.vertices.write(to: directory.appending(path: meshVerticesFilename(mesh.id)), options: .atomic)
            try mesh.faces.write(to: directory.appending(path: meshFacesFilename(mesh.id)), options: .atomic)
            try mesh.normals.write(to: directory.appending(path: meshNormalsFilename(mesh.id)), options: .atomic)
            if let classification = mesh.classification {
                try classification.write(to: directory.appending(path: meshClassificationFilename(mesh.id)), options: .atomic)
            }
        }
    }

    private static func rawDepthFilename(_ id: String) -> String { "\(id).depth-f32le" }
    private static func confidenceFilename(_ id: String) -> String { "\(id).confidence-u8" }
    private static func smoothedDepthFilename(_ id: String) -> String { "\(id).smoothed-depth-f32le" }
    private static func meshVerticesFilename(_ id: String) -> String { "\(id).mesh-vertices" }
    private static func meshFacesFilename(_ id: String) -> String { "\(id).mesh-faces" }
    private static func meshNormalsFilename(_ id: String) -> String { "\(id).mesh-normals" }
    private static func meshClassificationFilename(_ id: String) -> String { "\(id).mesh-classification-u8" }

    static func stageOriginals(id: String, rawData: Data, roomPlanData: Data) throws {
        let directory = try directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rawData.write(to: directory.appending(path: "raw-snapshot.json"), options: .atomic)
        try roomPlanData.write(to: directory.appending(path: "roomplan.json"), options: .atomic)
    }

    static func saveScene(_ scene: ProcessedScene, for bundle: CaptureBundle) throws {
        guard scene.sourceScanID == bundle.id, scene.mapID == bundle.mapID, scene.floorID == bundle.floorID else {
            throw CaptureValidationError.invalid("The room view belongs to a different scan.")
        }
        try scene.validate(source: bundle)
        try JSONEncoder().encode(scene).write(to: try directory(for: bundle.id).appending(path: "scene.json"), options: .atomic)
    }

    static func select(_ bundle: CaptureBundle) throws {
        try JSONEncoder().encode(bundle.id).write(to: activeURL, options: .atomic)
    }

    static func clearSelection() {
        try? FileManager.default.removeItem(at: activeURL)
    }

    static func loadSavedBundle() -> CaptureBundle? {
        guard let idData = try? Data(contentsOf: activeURL),
              let id = try? JSONDecoder().decode(String.self, from: idData),
              let directory = try? directory(for: id),
              let data = try? Data(contentsOf: directory.appending(path: "capture.json")),
              let bundle = try? JSONDecoder().decode(CaptureBundle.self, from: data),
              bundle.id == id, (try? bundle.validate()) != nil else { return nil }
        return bundle
    }

    static func loadSavedScene() -> ProcessedScene? {
        guard let bundle = loadSavedBundle(),
              let directory = try? directory(for: bundle.id),
              let data = try? Data(contentsOf: directory.appending(path: "scene.json")),
              let scene = try? JSONDecoder().decode(ProcessedScene.self, from: data),
              scene.sourceScanID == bundle.id, scene.mapID == bundle.mapID, scene.floorID == bundle.floorID,
              (try? scene.validate()) != nil else { return nil }
        return scene
    }

    static var savedBundleURL: URL? {
        guard let bundle = loadSavedBundle(), let directory = try? directory(for: bundle.id) else { return nil }
        return directory.appending(path: "capture.json")
    }

    static func worldMapURL(for captureID: String) -> URL? {
        try? directory(for: captureID).appending(path: "worldmap.archive")
    }

    /// Creates a portable sequential archive without expanding binary LiDAR buffers into the
    /// `CaptureBundle` JSON upload. The backend archive endpoint can ingest this immutable package.
    static func makeArchive(for captureID: String) throws -> URL {
        let source = try directory(for: captureID)
        try writePackageManifest(in: source, captureID: captureID)
        let archiveURL = source.deletingPathExtension().appendingPathExtension("inviewscan.tar")
        let files = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { file in
            file != archiveURL && (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let temporaryURL = archiveURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporaryURL)
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CaptureValidationError.invalid("Could not create the scan archive.")
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        do {
            for file in files {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try output.write(contentsOf: tarHeader(path: "\(captureID)/\(file.lastPathComponent)", size: size))
                try append(file: file, to: output)
                let padding = (512 - size % 512) % 512
                if padding > 0 { try output.write(contentsOf: Data(repeating: 0, count: padding)) }
            }
            try output.write(contentsOf: Data(repeating: 0, count: 1024))
            try output.close()
            try? FileManager.default.removeItem(at: archiveURL)
            try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
            return archiveURL
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// A machine-readable inventory for backend pipelines. It lets OCR/VLM and reconstruction jobs
    /// find calibrated RGB, depth, mesh, RoomPlan, and relocalization evidence without guessing
    /// filenames or inventing a second coordinate system.
    private static func writePackageManifest(in directory: URL, captureID: String) throws {
        let captureURL = directory.appending(path: "capture.json")
        let rawURL = directory.appending(path: "raw-snapshot.json")
        let bundle = try JSONDecoder().decode(CaptureBundle.self, from: Data(contentsOf: captureURL))
        guard bundle.id == captureID else { throw CaptureValidationError.invalid("The capture package identifier does not match its source.") }
        let raw = try? JSONDecoder().decode(RawScanSnapshot.self, from: Data(contentsOf: rawURL))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent != "package-manifest.json" && $0.pathExtension != "tar" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let assets = try files.map { file in
            let name = file.lastPathComponent
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return PackageManifest.Asset(path: name, role: assetRole(for: name), mediaType: mediaType(for: name), bytes: size)
        }
        let colorNames = Set(raw?.colorKeyframes.map(\.filename) ?? [])
        let buffers = Dictionary(uniqueKeysWithValues: (raw?.depthBuffers ?? []).map { ($0.id, $0) })
        let observations = bundle.frames.map { frame in
            let native = buffers[frame.id]
            let colorAsset = frame.colorAsset.flatMap { colorNames.contains($0) ? $0 : nil }
            return PackageManifest.Observation(
                id: frame.id, timestampSeconds: frame.timestampSeconds, rgbAsset: colorAsset,
                mapFromCamera: frame.mapFromCamera,
                image: .init(width: frame.camera.imageWidth, height: frame.camera.imageHeight,
                             fx: frame.camera.fx, fy: frame.camera.fy, cx: frame.camera.cx, cy: frame.camera.cy),
                rawDepth: native.map { .init(rawAsset: rawDepthFilename($0.id), confidenceAsset: $0.confidence == nil ? nil : confidenceFilename($0.id),
                                               smoothedAsset: $0.smoothedDepth == nil ? nil : smoothedDepthFilename($0.id),
                                               width: $0.width, height: $0.height, bytesPerRow: $0.bytesPerRow,
                                               pixelFormat: $0.pixelFormat, confidenceBytesPerRow: $0.confidenceBytesPerRow,
                                               environment: $0.environment, smoothedWidth: $0.smoothedWidth,
                                               smoothedHeight: $0.smoothedHeight, smoothedBytesPerRow: $0.smoothedBytesPerRow,
                                               smoothedPixelFormat: $0.smoothedPixelFormat) }
            )
        }
        let meshAnchors = (raw?.meshBuffers ?? []).map { mesh in
            PackageManifest.MeshAnchor(
                id: mesh.id, mapFromAnchor: mesh.mapFromAnchor,
                verticesAsset: meshVerticesFilename(mesh.id), facesAsset: meshFacesFilename(mesh.id),
                normalsAsset: meshNormalsFilename(mesh.id), classificationAsset: mesh.classification == nil ? nil : meshClassificationFilename(mesh.id),
                vertexOffset: mesh.vertexOffset, vertexStride: mesh.vertexStride, vertexFormat: mesh.vertexFormat,
                vertexCount: mesh.vertexCount, bytesPerIndex: mesh.bytesPerIndex, faceCount: mesh.faceCount,
                indicesPerFace: mesh.indicesPerFace, normalOffset: mesh.normalOffset, normalStride: mesh.normalStride,
                normalFormat: mesh.normalFormat, classificationOffset: mesh.classificationOffset,
                classificationStride: mesh.classificationStride
            )
        }
        let manifest = PackageManifest(
            captureID: bundle.id, mapID: bundle.mapID, floorID: bundle.floorID,
            coordinateFrame: .init(units: bundle.coordinates.units, upAxis: bundle.coordinates.upAxis,
                                   handedness: bundle.coordinates.handedness, name: "shared_arkit_session"),
            assets: assets, observations: observations, meshAnchors: meshAnchors
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: directory.appending(path: "package-manifest.json"), options: .atomic)
    }

    private static func assetRole(for filename: String) -> String {
        if filename == "capture.json" { return "portable_capture" }
        if filename == "roomplan.json" { return "roomplan_original" }
        if filename == "raw-snapshot.json" { return "raw_lidar_snapshot" }
        if filename == "worldmap.archive" { return "arkit_world_map" }
        if filename == "scene.json" { return "derived_scene" }
        if filename.hasSuffix(".color.jpg") { return "rgb_keyframe" }
        if filename.hasSuffix(".depth-f32le") { return "raw_depth_float32" }
        if filename.hasSuffix(".smoothed-depth-f32le") { return "smoothed_depth_float32" }
        if filename.hasSuffix(".confidence-u8") { return "depth_confidence" }
        if filename.hasSuffix(".mesh-vertices") { return "mesh_vertices" }
        if filename.hasSuffix(".mesh-faces") { return "mesh_indices" }
        if filename.hasSuffix(".mesh-normals") { return "mesh_normals" }
        if filename.hasSuffix(".mesh-classification-u8") { return "mesh_classification" }
        return "opaque_sidecar"
    }

    private static func mediaType(for filename: String) -> String {
        if filename.hasSuffix(".json") { return "application/json" }
        if filename.hasSuffix(".jpg") { return "image/jpeg" }
        return "application/octet-stream"
    }

    private static func append(file: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private static func tarHeader(path: String, size: Int) -> Data {
        var header = [UInt8](repeating: 0, count: 512)

        func write(_ value: String, at offset: Int, length: Int) {
            let bytes = Array(value.utf8.prefix(length))
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        func writeOctal(_ value: Int, at offset: Int, length: Int) {
            let text = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, length - text.count - 1)) + text + "\0"
            write(padded, at: offset, length: length)
        }

        write(path, at: 0, length: 100)
        writeOctal(0o644, at: 100, length: 8)
        writeOctal(0, at: 108, length: 8)
        writeOctal(0, at: 116, length: 8)
        writeOctal(size, at: 124, length: 12)
        writeOctal(Int(Date().timeIntervalSince1970), at: 136, length: 12)
        for index in 148..<156 { header[index] = 32 }
        header[156] = UInt8(ascii: "0")
        write("ustar", at: 257, length: 6)
        write("00", at: 263, length: 2)
        write(String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }), at: 148, length: 8)
        return Data(header)
    }

    private static func directory(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else {
            throw CaptureValidationError.invalid("The saved capture identifier is invalid.")
        }
        return root.appending(path: id, directoryHint: .isDirectory)
    }
}

private struct PackageManifest: Codable {
    struct CoordinateFrame: Codable {
        var units: String
        var upAxis: String
        var handedness: String
        var name: String
        enum CodingKeys: String, CodingKey { case units, upAxis = "up_axis", handedness, name }
    }
    struct Asset: Codable {
        var path: String
        var role: String
        var mediaType: String
        var bytes: Int
        enum CodingKeys: String, CodingKey { case path, role, mediaType = "media_type", bytes }
    }
    struct Observation: Codable {
        struct Image: Codable {
            var width: Int
            var height: Int
            var fx: Float
            var fy: Float
            var cx: Float
            var cy: Float
        }
        struct NativeDepth: Codable {
            var rawAsset: String
            var confidenceAsset: String?
            var smoothedAsset: String?
            var width: Int
            var height: Int
            var bytesPerRow: Int
            var pixelFormat: UInt32
            var confidenceBytesPerRow: Int?
            var environment: CaptureEnvironmentSample?
            var smoothedWidth: Int?
            var smoothedHeight: Int?
            var smoothedBytesPerRow: Int?
            var smoothedPixelFormat: UInt32?
            enum CodingKeys: String, CodingKey {
                case rawAsset = "raw_asset", confidenceAsset = "confidence_asset", smoothedAsset = "smoothed_asset"
                case width, height, bytesPerRow = "bytes_per_row", pixelFormat = "pixel_format"
                case confidenceBytesPerRow = "confidence_bytes_per_row", environment, smoothedWidth = "smoothed_width"
                case smoothedHeight = "smoothed_height", smoothedBytesPerRow = "smoothed_bytes_per_row"
                case smoothedPixelFormat = "smoothed_pixel_format"
            }
        }
        var id: String
        var timestampSeconds: Double
        var rgbAsset: String?
        var mapFromCamera: [Float]
        var image: Image
        var rawDepth: NativeDepth?
        enum CodingKeys: String, CodingKey {
            case id, timestampSeconds = "timestamp_seconds", rgbAsset = "rgb_asset"
            case mapFromCamera = "map_from_camera", image, rawDepth = "raw_depth"
        }
    }

    struct MeshAnchor: Codable {
        var id: String
        var mapFromAnchor: [Float]
        var verticesAsset: String
        var facesAsset: String
        var normalsAsset: String
        var classificationAsset: String?
        var vertexOffset: Int
        var vertexStride: Int
        var vertexFormat: UInt
        var vertexCount: Int
        var bytesPerIndex: Int
        var faceCount: Int
        var indicesPerFace: Int
        var normalOffset: Int
        var normalStride: Int
        var normalFormat: UInt
        var classificationOffset: Int?
        var classificationStride: Int?
        enum CodingKeys: String, CodingKey {
            case id, mapFromAnchor = "map_from_anchor", verticesAsset = "vertices_asset", facesAsset = "faces_asset"
            case normalsAsset = "normals_asset", classificationAsset = "classification_asset", vertexOffset = "vertex_offset"
            case vertexStride = "vertex_stride", vertexFormat = "vertex_format", vertexCount = "vertex_count"
            case bytesPerIndex = "bytes_per_index", faceCount = "face_count", indicesPerFace = "indices_per_face"
            case normalOffset = "normal_offset", normalStride = "normal_stride", normalFormat = "normal_format"
            case classificationOffset = "classification_offset", classificationStride = "classification_stride"
        }
    }

    var schemaVersion = 1
    var captureID: String
    var mapID: String
    var floorID: String
    var coordinateFrame: CoordinateFrame
    var assets: [Asset]
    var observations: [Observation]
    var meshAnchors: [MeshAnchor]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", captureID = "capture_id", mapID = "map_id", floorID = "floor_id"
        case coordinateFrame = "coordinate_frame", assets, observations, meshAnchors = "mesh_anchors"
    }
}
