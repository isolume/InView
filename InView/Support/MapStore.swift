import ARKit
import AccessCore
import Foundation
import RoomPlan
import UIKit

/// Saves each building floor separately and publishes its selection after all assets are ready.
enum MapStore {
    static let selectionDidChange = Notification.Name("InView.savedFloorSelectionDidChange")
    private static var directory: URL { URL.documentsDirectory }
    private static var buildingsDirectory: URL { directory.appending(path: "Buildings", directoryHint: .isDirectory) }
    private static var registryURL: URL { directory.appending(path: "saved-buildings.json") }
    private static let publicationLock = NSRecursiveLock()

    /// Older flat saves remain a fallback until a complete saved floor is selected.
    private static var selectedDirectory: URL { resolvedSelection()?.directory ?? directory }
    static var mapURL: URL { selectedDirectory.appending(path: "venue-map.json") }
    /// The scan session's map of visual features. Navigation relocalizes against it so saved coordinates line up.
    static var worldMapURL: URL { selectedDirectory.appending(path: "venue.arworldmap") }
    /// The camera view where the scan started, shown to riders while relocalizing.
    static var startViewURL: URL { selectedDirectory.appending(path: "start-view.jpg") }
    static var reportURL: URL { selectedDirectory.appending(path: "venue-report.json") }
    /// Raw RoomPlan output, kept so the floor plan can be rebuilt later with better logic.
    static var roomsURL: URL { selectedDirectory.appending(path: "captured-rooms.json") }

    static var currentFloor: SavedFloor? { resolvedSelection()?.floor }
    static var currentBuilding: SavedBuilding? { resolvedSelection()?.building }
    static var activeCaptureID: String? { currentFloor?.captureID }

    static func savedBuildings() -> [SavedBuilding] {
        publicationLock.withLock {
            guard let registry = try? readRegistry() else { return [] }
            return registry.buildings.compactMap { building in
                var available = building
                available.floors = building.floors.filter { isCompleteFloor($0) }
                return available.floors.isEmpty ? nil : available
            }
        }
    }

    static func selectFloor(buildingID: UUID, floorID: UUID) throws {
        try publicationLock.withLock {
            var registry = try readRegistry()
            try registry.select(buildingID: buildingID, floorID: floorID)
            guard let floor = registry.selectedFloor, isCompleteFloor(floor) else {
                throw SavedFloorStorageError.missingFloor
            }
            try encoder.encode(registry).write(to: registryURL, options: .atomic)
            notifySelectionChanged()
        }
    }

    /// Map browsing is independent of the optional assets needed for live AR positioning.
    static func load() -> VenueMap? {
        let selected = selectedDirectory
        guard let data = try? Data(contentsOf: selected.appending(path: "venue-map.json")) else { return nil }
        return try? decoder.decode(VenueMap.self, from: data)
    }

    /// Captured with the exact local map, before report/planner work can suspend its caller.
    struct PlaceEditSource: Sendable, Equatable {
        fileprivate var directory: URL
        fileprivate var storageID: UUID?
        fileprivate var mapData: Data
    }

    static func loadEditableMap() -> (map: VenueMap, source: PlaceEditSource)? {
        publicationLock.withLock {
            let selected = resolvedSelection()
            let folder = selected?.directory ?? directory
            guard let data = try? Data(contentsOf: folder.appending(path: "venue-map.json")),
                  let map = try? decoder.decode(VenueMap.self, from: data) else { return nil }
            return (map, PlaceEditSource(directory: folder, storageID: selected?.floor.storageID, mapData: data))
        }
    }

    /// Refreshes a source after a synchronous edit only when the controller still shows that map.
    static func placeEditSource(matching map: VenueMap) -> PlaceEditSource? {
        guard let saved = loadEditableMap() else { return nil }
        let encoder = encoder
        encoder.outputFormatting = [.sortedKeys]
        guard let expected = try? encoder.encode(map), let actual = try? encoder.encode(saved.map),
              expected == actual else { return nil }
        return saved.source
    }

    static func loadWorldMap() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    static func loadStartView() -> UIImage? {
        UIImage(contentsOfFile: startViewURL.path())
    }

    static func updateGeographicReference(_ reference: BuildingMapReference) throws {
        try reference.validate()
        _ = try republish(notifies: true) { $0.geographicReference = reference }
    }

    /// The report and new places belong to the expected original, never to a newly selected floor.
    @discardableResult
    static func updatePoints(_ points: [AccessPoint], report: AccessibilityReport,
                             expected source: PlaceEditSource) throws -> PlaceEditSource {
        try republish(notifies: false, report: report, expected: source) { $0.points = points }
    }

    /// Publish a new saved revision while preserving the prior floor and its original scan assets.
    private static func republish(notifies: Bool, report: AccessibilityReport? = nil,
                                  expected: PlaceEditSource? = nil,
                                  _ edit: (inout VenueMap) -> Void) throws -> PlaceEditSource {
        try publicationLock.withLock {
            try Task.checkCancellation()
            let selected = resolvedSelection()
            let source = selected?.directory ?? directory
            let originalData = try Data(contentsOf: source.appending(path: "venue-map.json"))
            if let expected {
                guard expected.directory == source, expected.storageID == selected?.floor.storageID,
                      expected.mapData == originalData else {
                    throw CaptureValidationError.invalid("The saved map changed. Open it again before editing places.")
                }
            }
            var map = try decoder.decode(VenueMap.self, from: originalData)
            edit(&map)
            let editedData = try encoder.encode(map)
            let reportData = try report.map { try encoder.encode($0) }
            func write(into folder: URL) throws {
                try Task.checkCancellation()
                try editedData.write(to: folder.appending(path: "venue-map.json"), options: .atomic)
                if let reportData {
                    try reportData.write(to: folder.appending(path: "venue-report.json"), options: .atomic)
                }
            }
            guard let selected else {
                try write(into: source)
                return PlaceEditSource(directory: source, storageID: nil, mapData: editedData)
            }
            let storageID = UUID()
            let destination = floorDirectory(identity: selected.floor.identity, storageID: storageID)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                try write(into: destination)
                var registry = selected.registry
                try registry.record(selected.floor.identity, storageID: storageID,
                                    captureID: selected.floor.captureID)
                try Task.checkCancellation()
                try encoder.encode(registry).write(to: registryURL, options: .atomic)
                if notifies { notifySelectionChanged() }
                return PlaceEditSource(directory: destination, storageID: storageID, mapData: editedData)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    static func loadReport() -> AccessibilityReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? decoder.decode(AccessibilityReport.self, from: data)
    }

    /// Everything one save writes, moved as one value into the writing task.
    private struct Payload: @unchecked Sendable {
        let map: VenueMap
        let report: AccessibilityReport
        let rooms: [CapturedRoom]
        let worldMap: ARWorldMap
        let startView: Data?
        let floor: ScanFloorIdentity?
        let buildingName: String?
        let captureID: String?
    }

    /// Archives the world map (several megabytes, slow) and writes everything, off the calling thread.
    static func save(_ map: VenueMap, report: AccessibilityReport, rooms: [CapturedRoom], worldMap: ARWorldMap,
                     startView: Data?, floor: ScanFloorIdentity? = nil, buildingName: String? = nil,
                     captureID: String? = nil) async throws {
        let payload = Payload(map: map, report: report, rooms: rooms, worldMap: worldMap,
                              startView: startView, floor: floor, buildingName: buildingName, captureID: captureID)
        let writer = Task.detached(priority: .userInitiated) { try write(payload) }
        try await withTaskCancellationHandler {
            try await writer.value
        } onCancel: {
            writer.cancel()
        }
    }

    private static func write(_ payload: Payload) throws {
        let started = Date.now
        if let captureID = payload.captureID, UUID(uuidString: captureID) == nil {
            throw SavedFloorStorageError.invalidCaptureID
        }
        try Task.checkCancellation()
        let archivedWorldMap = try NSKeyedArchiver.archivedData(withRootObject: payload.worldMap, requiringSecureCoding: true)
        let identity = payload.floor ?? currentFloor?.identity ?? ScanFloorIdentity(level: 1)
        let storageID = UUID()
        let destination = floorDirectory(identity: identity, storageID: storageID)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try archivedWorldMap.write(to: destination.appending(path: "venue.arworldmap"), options: .atomic)
            try encoder.encode(payload.map).write(to: destination.appending(path: "venue-map.json"), options: .atomic)
            try encoder.encode(payload.report).write(to: destination.appending(path: "venue-report.json"), options: .atomic)
            try encoder.encode(payload.rooms).write(to: destination.appending(path: "captured-rooms.json"), options: .atomic)
            if let startView = payload.startView {
                try startView.write(to: destination.appending(path: "start-view.jpg"), options: .atomic)
            }
            try Task.checkCancellation()
            try publicationLock.withLock {
                try Task.checkCancellation()
                var registry = try readRegistry()
                try registry.record(identity, buildingName: payload.buildingName,
                                    storageID: storageID, captureID: payload.captureID)
                // A single atomic publication selects the map and its matching capture together.
                try encoder.encode(registry).write(to: registryURL, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        Log.scan.info("saved map in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s · world map \(archivedWorldMap.count / 1024) KB")
        notifySelectionChanged()
    }

    private static func notifySelectionChanged() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: selectionDidChange, object: nil) }
    }

    private struct ResolvedSelection {
        var registry: SavedFloorRegistry
        var building: SavedBuilding
        var floor: SavedFloor
        var directory: URL
    }

    private static func resolvedSelection() -> ResolvedSelection? {
        publicationLock.withLock {
            guard let registry = try? readRegistry(),
                  let building = registry.selectedBuilding,
                  let floor = registry.selectedFloor, isCompleteFloor(floor) else { return nil }
            return ResolvedSelection(registry: registry, building: building, floor: floor,
                                     directory: floorDirectory(identity: floor.identity, storageID: floor.storageID))
        }
    }

    private static func readRegistry() throws -> SavedFloorRegistry {
        guard FileManager.default.fileExists(atPath: registryURL.path()) else { return SavedFloorRegistry() }
        let registry = try decoder.decode(SavedFloorRegistry.self, from: Data(contentsOf: registryURL))
        try registry.validate()
        return registry
    }

    /// All path components come from decoded UUID values, never user-entered floor or building names.
    private static func floorDirectory(identity: ScanFloorIdentity, storageID: UUID) -> URL {
        buildingsDirectory
            .appending(path: identity.buildingID.uuidString, directoryHint: .isDirectory)
            .appending(path: identity.id.uuidString, directoryHint: .isDirectory)
            .appending(path: storageID.uuidString, directoryHint: .isDirectory)
    }

    private static func isCompleteFloor(_ floor: SavedFloor) -> Bool {
        let location = floorDirectory(identity: floor.identity, storageID: floor.storageID)
        guard let data = try? Data(contentsOf: location.appending(path: "venue-map.json")),
            (try? decoder.decode(VenueMap.self, from: data)) != nil else { return false }
        return true
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
