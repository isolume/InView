import ARKit
import AccessCore
import Foundation
import RoomPlan
import UIKit

/// Keeps the one saved venue map in the app's Documents folder.
enum MapStore {
    private static var directory: URL { URL.documentsDirectory }
    static var mapURL: URL { directory.appending(path: "venue-map.json") }
    /// The scan session's map of visual features. Navigation relocalizes against it so saved coordinates line up.
    static var worldMapURL: URL { directory.appending(path: "venue.arworldmap") }
    /// The camera view where the scan started, shown to riders while relocalizing.
    static var startViewURL: URL { directory.appending(path: "start-view.jpg") }
    static var reportURL: URL { directory.appending(path: "venue-report.json") }
    /// Raw RoomPlan output, kept so the floor plan can be rebuilt later with better logic.
    static var roomsURL: URL { directory.appending(path: "captured-rooms.json") }

    /// Nil unless the AR world map is saved too, since navigation can't line up without it.
    static func load() -> VenueMap? {
        guard FileManager.default.fileExists(atPath: worldMapURL.path()),
              let data = try? Data(contentsOf: mapURL) else { return nil }
        return try? decoder.decode(VenueMap.self, from: data)
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
        var map = try decoder.decode(VenueMap.self, from: Data(contentsOf: mapURL))
        map.geographicReference = reference
        try encoder.encode(map).write(to: mapURL, options: .atomic)
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
    }

    /// Archives the world map (several megabytes, slow) and writes everything, off the calling thread.
    static func save(_ map: VenueMap, report: AccessibilityReport, rooms: [CapturedRoom], worldMap: ARWorldMap, startView: Data?) async throws {
        let payload = Payload(map: map, report: report, rooms: rooms, worldMap: worldMap, startView: startView)
        try await Task.detached(priority: .userInitiated) { try write(payload) }.value
    }

    private static func write(_ payload: Payload) throws {
        let started = Date.now
        let archivedWorldMap = try NSKeyedArchiver.archivedData(withRootObject: payload.worldMap, requiringSecureCoding: true)
        try archivedWorldMap.write(to: worldMapURL, options: .atomic)
        try encoder.encode(payload.map).write(to: mapURL, options: .atomic)
        try encoder.encode(payload.report).write(to: reportURL, options: .atomic)
        try encoder.encode(payload.rooms).write(to: roomsURL, options: .atomic)
        if let startView = payload.startView {
            try startView.write(to: startViewURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: startViewURL)
        }
        Log.scan.info("saved map in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s · world map \(archivedWorldMap.count / 1024) KB")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
