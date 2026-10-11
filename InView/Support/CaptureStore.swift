import AccessCore
import Foundation

/// Each source scan and its derived scene have their own files. Saving a map selects its capture.
enum CaptureStore {
    private static var root: URL { URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory) }
    private static var activeURL: URL { URL.documentsDirectory.appending(path: "active-capture.json") }

    static func stage(_ bundle: CaptureBundle, rawData: Data, roomPlanData: Data) throws {
        try stageOriginals(id: bundle.id, rawData: rawData, roomPlanData: roomPlanData)
        try stageBundle(bundle)
    }

    /// Originals have already been secured; do not rewrite large archives to save their projection.
    static func stageBundle(_ bundle: CaptureBundle) throws {
        try Task.checkCancellation()
        let directory = try directory(for: bundle.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(bundle).write(to: directory.appending(path: "capture.json"), options: .atomic)
    }

    static func stageOriginals(id: String, rawData: Data, roomPlanData: Data) throws {
        try Task.checkCancellation()
        let directory = try directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rawData.write(to: directory.appending(path: "raw-snapshot.json"), options: .atomic)
        try roomPlanData.write(to: directory.appending(path: "roomplan.json"), options: .atomic)
    }

    static func stageRawSnapshot(id: String, data: Data) throws {
        try Task.checkCancellation()
        let folder = try directory(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: "raw-snapshot.json"), options: .atomic)
        } catch {
            throw RoomCaptureArchive.Failure.storage(error)
        }
    }

    /// Native metadata is separate from the validated measurements used for navigation.
    static func stageNativeRooms<Value: Encodable>(id: String, rooms: Value) throws {
        _ = try RoomCaptureArchive.writeJSON(rooms, to: try directory(for: id).appending(path: "roomplan.json"))
    }

    /// Keeps calibrated evidence beside the canonical capture without embedding binary data in JSON.
    /// Call after staging the bundle, whose map and floor identify the unchanged ARKit frame.
    static func stageEvidence(_ raw: RawScanSnapshot, id: String) throws {
        try Task.checkCancellation()
        let folder = try directory(for: id)
        let bundle = try JSONDecoder().decode(CaptureBundle.self, from: boundedData(at: folder.appending(path: "capture.json")))
        guard bundle.id == id else { throw invalidEvidence() }
        var validation = bundle
        validation.frames = raw.frames
        try validation.validate()
        guard Set(raw.depthBuffers.map(\.id)).count == raw.depthBuffers.count,
              Set((raw.colorKeyframes ?? []).map(\.frameID)).count == (raw.colorKeyframes ?? []).count else {
            throw invalidEvidence()
        }
        let frames = Dictionary(uniqueKeysWithValues: raw.frames.map { ($0.id, $0) })
        let colors = Dictionary(uniqueKeysWithValues: (raw.colorKeyframes ?? []).map { ($0.frameID, $0) })
        let depthIDs = Set(raw.depthBuffers.map(\.id))
        guard Set(colors.keys).isSubset(of: depthIDs) else { throw invalidEvidence() }
        var assets: [EvidenceAsset] = []
        var observations: [EvidenceObservation] = []
        func write(_ data: Data, named name: String, role: String, mediaType: String) throws {
            try Task.checkCancellation()
            try validateFilename(name)
            guard data.count <= maximumFileBytes else { throw oversizedEvidence() }
            try data.write(to: folder.appending(path: name), options: .atomic)
            assets.append(EvidenceAsset(path: name, role: role, mediaType: mediaType, bytes: data.count))
        }
        for native in raw.depthBuffers {
            guard let frame = frames[native.id] else { throw invalidEvidence() }
            let depth = EvidenceDepth(native)
            try depth.validate(depthBytes: native.depth.count, confidenceBytes: native.confidence?.count)
            try write(native.depth, named: depth.rawAsset, role: "native_depth", mediaType: "application/octet-stream")
            if let confidence = native.confidence, let name = depth.confidenceAsset {
                try write(confidence, named: name, role: "depth_confidence", mediaType: "application/octet-stream")
            }
            let color = colors[native.id]
            if let color {
                guard (1...16_384).contains(color.width), (1...16_384).contains(color.height),
                      color.jpeg.starts(with: [0xff, 0xd8]) else { throw invalidEvidence() }
                try write(color.jpeg, named: color.filename, role: "rgb_keyframe", mediaType: "image/jpeg")
            }
            observations.append(EvidenceObservation(frame: frame, depth: depth, color: color))
        }
        if let track = raw.cameraTrack {
            try write(JSONEncoder().encode(track), named: "camera-track.json", role: "camera_track", mediaType: "application/json")
        }
        for (name, role) in supportFiles where !assets.contains(where: { $0.path == name }) {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                assets.append(try asset(at: url, named: name, role: role, mediaType: "application/json"))
            }
        }
        assets.append(try asset(at: folder.appending(path: "capture.json"), named: "capture.json",
                                role: "portable_capture", mediaType: "application/json"))
        let manifest = EvidenceManifest(bundle: bundle, assets: assets, observations: observations)
        let data = try JSONEncoder().encode(manifest)
        try validatePackageSize(assets: assets + [EvidenceAsset(path: "package-manifest.json", role: "manifest",
                                                                mediaType: "application/json", bytes: data.count)])
        try data.write(to: folder.appending(path: "package-manifest.json"), options: .atomic)
    }

    /// Each explicit analysis request is immutable and separate from the saved navigation capture.
    /// Only indexed depth/RGB and the named support files may leave the device in this package.
    static func makeAnalysisPackage(_ bundle: CaptureBundle) throws -> (capture: CaptureBundle, archiveURL: URL) {
        try Task.checkCancellation()
        try bundle.validate()
        let source = try directory(for: bundle.id)
        let manifestURL = source.appending(path: "package-manifest.json")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try stageEvidence(loadRawSnapshot(id: bundle.id), id: bundle.id)
        }
        let saved = try JSONDecoder().decode(EvidenceManifest.self, from: boundedData(at: manifestURL))
        guard saved.schemaVersion == 1, saved.captureID == bundle.id, saved.mapID == bundle.mapID,
              saved.floorID == bundle.floorID, saved.coordinateFrame == EvidenceCoordinates(bundle.coordinates),
              !saved.observations.isEmpty, saved.observations.contains(where: { $0.rgbAsset != nil }),
              Set(saved.observations.map(\.id)).count == saved.observations.count,
              Set(saved.assets.map(\.path)).count == saved.assets.count else {
            throw CaptureValidationError.invalid("This scan has no complete saved photo and depth evidence. Make a new scan to find places.")
        }
        let indexed = Dictionary(uniqueKeysWithValues: saved.assets.map { ($0.path, $0) })
        var required = Set<String>()
        for observation in saved.observations {
            try observation.validate()
            required.insert(observation.rawDepth.rawAsset)
            if let name = observation.rawDepth.confidenceAsset { required.insert(name) }
            if let name = observation.rgbAsset { required.insert(name) }
        }
        for frame in bundle.frames {
            if let name = frame.colorAsset, !required.contains(name) { throw invalidEvidence() }
        }
        var capture = bundle
        capture.id = UUID().uuidString
        var metadata: [String: JSONValue]
        if case .object(let original) = bundle.metadata { metadata = original }
        else { metadata = ["source_metadata": bundle.metadata ?? .null] }
        metadata["source_capture_id"] = .string(bundle.id)
        metadata["source_map_id"] = .string(bundle.mapID)
        metadata["source_floor_id"] = .string(bundle.floorID)
        capture.metadata = .object(metadata)
        let folder = FileManager.default.temporaryDirectory.appending(path: "inview-analysis-\(capture.id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        var assets: [EvidenceAsset] = []
        let captureURL = folder.appending(path: "capture.json")
        let captureData = try JSONEncoder().encode(capture)
        guard captureData.count <= maximumFileBytes else { throw oversizedEvidence() }
        try captureData.write(to: captureURL, options: .atomic)
        assets.append(EvidenceAsset(path: "capture.json", role: "portable_capture", mediaType: "application/json", bytes: captureData.count))
        for name in required.sorted() {
            guard let record = indexed[name], !supportFiles.keys.contains(name), name != "capture.json",
                  record.role == "native_depth" || record.role == "depth_confidence" || record.role == "rgb_keyframe" else {
                throw invalidEvidence()
            }
            let actual = try asset(at: source.appending(path: name), named: name, role: record.role, mediaType: record.mediaType)
            guard actual.bytes == record.bytes else { throw invalidEvidence() }
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source.appending(path: name), to: folder.appending(path: name))
            assets.append(actual)
            try validatePackageSize(assets: assets)
        }
        for (name, role) in supportFiles.sorted(by: { $0.key < $1.key }) {
            let url = source.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let record = try asset(at: url, named: name, role: role, mediaType: "application/json")
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: url, to: folder.appending(path: name))
            assets.append(record)
            try validatePackageSize(assets: assets)
        }
        for observation in saved.observations {
            guard let depth = assets.first(where: { $0.path == observation.rawDepth.rawAsset }) else { throw invalidEvidence() }
            let confidenceBytes = observation.rawDepth.confidenceAsset.flatMap { name in assets.first(where: { $0.path == name })?.bytes }
            try observation.rawDepth.validate(depthBytes: depth.bytes, confidenceBytes: confidenceBytes)
        }
        let manifest = EvidenceManifest(bundle: capture, assets: assets, observations: saved.observations)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: folder.appending(path: "package-manifest.json"), options: .atomic)
        assets.append(EvidenceAsset(path: "package-manifest.json", role: "manifest", mediaType: "application/json", bytes: manifestData.count))
        try validatePackageSize(assets: assets)
        let archiveURL = folder.appending(path: "\(capture.id).inviewscan.tar")
        try writePackage(assets: assets, folder: folder, captureID: capture.id, to: archiveURL)
        completed = true
        return (capture, archiveURL)
    }

    /// Optional detail never replaces the canonical RoomPlan projection or its scene.
    static func saveDetailScene(_ scene: ProcessedScene, for bundle: CaptureBundle) throws {
        try Task.checkCancellation()
        try scene.validate(source: bundle)
        let folder = try directory(for: bundle.id)
        let canonical = try JSONDecoder().decode(CaptureBundle.self, from: boundedData(at: folder.appending(path: "capture.json")))
        guard canonical.id == bundle.id, canonical.mapID == bundle.mapID, canonical.floorID == bundle.floorID else {
            throw invalidEvidence()
        }
        let data = try JSONEncoder().encode(DetailRecord(capture: bundle, scene: scene))
        guard data.count <= maximumFileBytes else { throw oversizedEvidence() }
        try Task.checkCancellation()
        // Commit the matched pair together: a failed color save must preserve the gray model.
        try data.write(to: folder.appending(path: "detail.json"), options: .atomic)
    }

    static func loadDetailScene(for captureID: String) -> ProcessedScene? {
        guard let folder = try? directory(for: captureID),
              let canonicalData = try? boundedData(at: folder.appending(path: "capture.json")),
              let canonical = try? JSONDecoder().decode(CaptureBundle.self, from: canonicalData),
              let data = try? boundedData(at: folder.appending(path: "detail.json")),
              let record = try? JSONDecoder().decode(DetailRecord.self, from: data),
              canonical.id == captureID, record.capture.id == captureID, canonical.mapID == record.capture.mapID,
              canonical.floorID == record.capture.floorID, (try? canonical.validate()) != nil,
              (try? record.scene.validate(source: record.capture)) != nil else { return nil }
        return record.scene
    }

    private struct DetailRecord: Codable {
        var capture: CaptureBundle
        var scene: ProcessedScene
    }

    /// Archive Apple's opaque input when its serializer supports it, before processing.
    static func stageRoomCaptureData<Value: Encodable>(id: String, roomID: UUID, value: Value) throws {
        try Task.checkCancellation()
        let directory = try directory(for: id).appending(path: "roomplan-source", directoryHint: .isDirectory)
        _ = try RoomCaptureArchive.writeJSON(value, to: directory.appending(path: roomID.uuidString + ".json"))
    }

    /// If the SDK cannot serialize its opaque input, keep its processed native result instead.
    static func stageProcessedRoom<Value: Encodable>(id: String, roomID: UUID, value: Value) throws {
        let directory = try directory(for: id).appending(path: "roomplan-rooms", directoryHint: .isDirectory)
        _ = try RoomCaptureArchive.writeJSON(value, to: directory.appending(path: roomID.uuidString + ".json"))
    }

    static func stageRoomStructure<Value: Encodable>(id: String, structure: Value) throws {
        _ = try RoomCaptureArchive.writeJSON(structure,
            to: try directory(for: id).appending(path: "roomplan-structure.json"))
    }

    static func loadRawSnapshot(id: String) throws -> RawScanSnapshot {
        try JSONDecoder().decode(RawScanSnapshot.self,
            from: Data(contentsOf: try directory(for: id).appending(path: "raw-snapshot.json")))
    }

    static func saveScene(_ scene: ProcessedScene, for bundle: CaptureBundle) throws {
        try Task.checkCancellation()
        guard scene.sourceScanID == bundle.id, scene.mapID == bundle.mapID, scene.floorID == bundle.floorID else {
            throw CaptureValidationError.invalid("The room view belongs to a different scan.")
        }
        try scene.validate(source: bundle)
        try Task.checkCancellation()
        try JSONEncoder().encode(scene).write(to: try directory(for: bundle.id).appending(path: "scene.json"), options: .atomic)
    }

    static func select(_ bundle: CaptureBundle) throws {
        try JSONEncoder().encode(bundle.id).write(to: activeURL, options: .atomic)
    }

    static func clearSelection() {
        try? FileManager.default.removeItem(at: activeURL)
    }

    static func loadSavedBundle() -> CaptureBundle? {
        let id: String?
        if MapStore.currentFloor != nil {
            id = MapStore.activeCaptureID
        } else if let idData = try? Data(contentsOf: activeURL) {
            id = try? JSONDecoder().decode(String.self, from: idData)
        } else {
            id = nil
        }
        guard let id,
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

    /// Posed photos for training a Gaussian splat of the scan, written while scanning.
    static func splatDirectory(for id: String) throws -> URL {
        try directory(for: id).appending(path: "splat", directoryHint: .isDirectory)
    }

    /// The capture's own directory (sidecars, originals, saved scene).
    static func captureDirectory(for id: String) throws -> URL {
        try directory(for: id)
    }

    /// Writes an extra evidence file (`semantics.json`, `text-observations.json`, `camera-track.json`)
    /// into the capture directory, from where it is sent with the scan.
    static func stageSidecar(_ data: Data, named filename: String, id: String) throws {
        let reserved: Set<String> = ["capture.json", "package-manifest.json", "raw-snapshot.json"]
        guard !filename.isEmpty, filename.count <= 64, !filename.hasPrefix("."), !reserved.contains(filename),
              filename.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
            throw CaptureValidationError.invalid("The capture sidecar name is invalid.")
        }
        let directory = try directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: filename), options: .atomic)
    }

    static func streamRoot(for id: String) throws -> URL {
        try directory(for: id).appending(path: "stream", directoryHint: .isDirectory)
    }

    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumPackageBytes = 256 * 1024 * 1024
    private static let supportFiles = ["roomplan.json": "roomplan_original", "semantics.json": "capture_semantics",
                                       "text-observations.json": "text_observations", "camera-track.json": "camera_track"]

    private static func invalidEvidence() -> CaptureValidationError {
        .invalid("The saved scan evidence is incomplete or does not match this scan.")
    }

    private static func oversizedEvidence() -> CaptureValidationError {
        .invalid("This scan is too large to send for place recognition.")
    }

    private static func validateFilename(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 63, !name.hasPrefix("."),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw invalidEvidence() }
    }

    private static func asset(at url: URL, named name: String, role: String, mediaType: String) throws -> EvidenceAsset {
        try Task.checkCancellation()
        try validateFilename(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
            throw invalidEvidence()
        }
        guard size <= maximumFileBytes else { throw oversizedEvidence() }
        return EvidenceAsset(path: name, role: role, mediaType: mediaType, bytes: size)
    }

    private static func boundedData(at url: URL) throws -> Data {
        let record = try asset(at: url, named: url.lastPathComponent, role: "local", mediaType: "application/json")
        let data = try Data(contentsOf: url)
        guard data.count == record.bytes else { throw invalidEvidence() }
        return data
    }

    private static func validatePackageSize(assets: [EvidenceAsset]) throws {
        guard assets.count <= 4096 else { throw oversizedEvidence() }
        var bytes = 1024
        for asset in assets {
            guard (0...maximumFileBytes).contains(asset.bytes) else { throw oversizedEvidence() }
            bytes += 512 + ((asset.bytes + 511) / 512) * 512
            guard bytes <= maximumPackageBytes else { throw oversizedEvidence() }
        }
    }

    /// USTAR regular files only, streamed from disk, matching the backend's two-component paths.
    private static func writePackage(assets: [EvidenceAsset], folder: URL, captureID: String, to output: URL) throws {
        try validatePackageSize(assets: assets)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw invalidEvidence()
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for asset in assets.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            try validateFilename(asset.path)
            let path = captureID + "/" + asset.path
            guard path.utf8.count <= 100 else { throw invalidEvidence() }
            var header = [UInt8](repeating: 0, count: 512)
            func text(_ text: String, at offset: Int, width: Int) {
                let data = Array(text.utf8)
                header.replaceSubrange(offset..<(offset + min(width, data.count)), with: data.prefix(width))
            }
            func octal(_ value: Int, at offset: Int, width: Int) {
                let number = String(value, radix: 8)
                text(String(repeating: "0", count: width - number.count - 1) + number + "\0", at: offset, width: width)
            }
            text(path, at: 0, width: 100)
            octal(0o600, at: 100, width: 8)
            octal(0, at: 108, width: 8)
            octal(0, at: 116, width: 8)
            octal(asset.bytes, at: 124, width: 12)
            octal(0, at: 136, width: 12)
            for index in 148..<156 { header[index] = 0x20 }
            header[156] = 0x30
            text("ustar\0", at: 257, width: 6)
            text("00", at: 263, width: 2)
            let checksum = String(header.reduce(0) { $0 + Int($1) }, radix: 8)
            text(String(repeating: "0", count: 6 - checksum.count) + checksum + "\0 ", at: 148, width: 8)
            try handle.write(contentsOf: Data(header))
            let input = try FileHandle(forReadingFrom: folder.appending(path: asset.path))
            do {
                defer { try? input.close() }
                var remaining = asset.bytes
                while remaining > 0 {
                    try Task.checkCancellation()
                    let data = try input.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
                    guard !data.isEmpty else { throw invalidEvidence() }
                    try handle.write(contentsOf: data)
                    remaining -= data.count
                }
                guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw invalidEvidence() }
            }
            let padding = (512 - asset.bytes % 512) % 512
            if padding > 0 { try handle.write(contentsOf: Data(repeating: 0, count: padding)) }
        }
        try Task.checkCancellation()
        try handle.write(contentsOf: Data(repeating: 0, count: 1024))
        try handle.synchronize()
    }

    private struct EvidenceAsset: Codable {
        var path: String
        var role: String
        var mediaType: String
        var bytes: Int
        enum CodingKeys: String, CodingKey { case path, role, mediaType = "media_type", bytes }
    }

    private struct EvidenceCoordinates: Codable, Equatable {
        var units: String
        var upAxis: String
        var handedness: String
        var name = "shared_arkit_session"
        init(_ value: CaptureCoordinates) {
            units = value.units; upAxis = value.upAxis; handedness = value.handedness
        }
        enum CodingKeys: String, CodingKey { case units, upAxis = "up_axis", handedness, name }
    }

    private struct EvidenceManifest: Codable {
        var schemaVersion = 1
        var captureID: String
        var mapID: String
        var floorID: String
        var coordinateFrame: EvidenceCoordinates
        var assets: [EvidenceAsset]
        var observations: [EvidenceObservation]
        var meshAnchors: [JSONValue] = []
        init(bundle: CaptureBundle, assets: [EvidenceAsset], observations: [EvidenceObservation]) {
            captureID = bundle.id; mapID = bundle.mapID; floorID = bundle.floorID
            coordinateFrame = EvidenceCoordinates(bundle.coordinates)
            self.assets = assets; self.observations = observations
        }
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", captureID = "capture_id", mapID = "map_id", floorID = "floor_id"
            case coordinateFrame = "coordinate_frame", assets, observations, meshAnchors = "mesh_anchors"
        }
    }

    private struct EvidenceImage: Codable {
        var width: Int
        var height: Int
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        init(_ camera: CaptureCameraCalibration) {
            width = camera.imageWidth; height = camera.imageHeight
            fx = camera.fx; fy = camera.fy; cx = camera.cx; cy = camera.cy
        }
    }

    private struct EvidenceObservation: Codable {
        var id: String
        var timestampSeconds: Double
        var mapFromCamera: [Float]
        var image: EvidenceImage
        var rgbAsset: String?
        var rgbWidth: Int?
        var rgbHeight: Int?
        var rgbOrientation: String?
        var rawDepth: EvidenceDepth
        init(frame: CaptureDepthFrame, depth: EvidenceDepth, color: RawColorKeyframe?) {
            id = frame.id; timestampSeconds = frame.timestampSeconds; mapFromCamera = frame.mapFromCamera
            image = EvidenceImage(frame.camera); rawDepth = depth; rgbAsset = color?.filename
            rgbWidth = color?.width; rgbHeight = color?.height
            rgbOrientation = color == nil ? nil : "sensor_rotated_90_clockwise"
        }
        func validate() throws {
            guard !id.isEmpty, timestampSeconds.isFinite, timestampSeconds >= 0,
                  (1...16_384).contains(image.width), (1...16_384).contains(image.height),
                  [image.fx, image.fy, image.cx, image.cy].allSatisfy(\.isFinite), image.fx > 0, image.fy > 0 else {
                throw CaptureStore.invalidEvidence()
            }
            // Reuse the canonical rigid-transform validator without materializing depth pixels.
            try CaptureBundle(id: "evidence", mapID: "evidence", surfaces: [
                CaptureSurface(id: id, kind: "evidence", mapFromSurface: mapFromCamera, dimensionsM: [1, 1, 0])
            ]).validate()
        }
        enum CodingKeys: String, CodingKey {
            case id, timestampSeconds = "timestamp_seconds", mapFromCamera = "map_from_camera", image
            case rgbAsset = "rgb_asset", rgbWidth = "rgb_width", rgbHeight = "rgb_height", rgbOrientation = "rgb_orientation"
            case rawDepth = "raw_depth"
        }
    }

    private struct EvidenceDepth: Codable {
        var rawAsset: String
        var confidenceAsset: String?
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var pixelFormat: UInt32
        var confidenceBytesPerRow: Int?
        var environment: CaptureEnvironmentSample?
        init(_ raw: RawDepthBuffers) {
            rawAsset = raw.id + ".depth-f32le"
            confidenceAsset = raw.confidence == nil ? nil : raw.id + ".confidence-u8"
            width = raw.width; height = raw.height; bytesPerRow = raw.bytesPerRow; pixelFormat = raw.pixelFormat
            confidenceBytesPerRow = raw.confidenceBytesPerRow; environment = raw.environment
        }
        func validate(depthBytes: Int, confidenceBytes: Int?) throws {
            guard (1...1024).contains(width), (1...1024).contains(height),
                  (width * 4...8192).contains(bytesPerRow), pixelFormat == 1_717_855_600,
                  depthBytes == bytesPerRow * height, environment?.isFinite != false else { throw CaptureStore.invalidEvidence() }
            if let confidenceAsset {
                try CaptureStore.validateFilename(confidenceAsset)
                guard let stride = confidenceBytesPerRow, (width...8192).contains(stride),
                      confidenceBytes == stride * height else { throw CaptureStore.invalidEvidence() }
            } else if confidenceBytes != nil || confidenceBytesPerRow != nil { throw CaptureStore.invalidEvidence() }
            try CaptureStore.validateFilename(rawAsset)
        }
        enum CodingKeys: String, CodingKey {
            case rawAsset = "raw_asset", confidenceAsset = "confidence_asset", width, height
            case bytesPerRow = "bytes_per_row", pixelFormat = "pixel_format", confidenceBytesPerRow = "confidence_bytes_per_row"
            case environment
        }
    }

    private static func directory(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else {
            throw CaptureValidationError.invalid("The saved capture identifier is invalid.")
        }
        return root.appending(path: id, directoryHint: .isDirectory)
    }
}
