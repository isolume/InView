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

    private static func directory(for id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else {
            throw CaptureValidationError.invalid("The saved capture identifier is invalid.")
        }
        return root.appending(path: id, directoryHint: .isDirectory)
    }
}
