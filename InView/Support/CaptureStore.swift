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
