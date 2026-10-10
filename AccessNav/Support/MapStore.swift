import AccessCore
import Foundation
import RoomPlan

/// Keeps the one saved venue map in the app's Documents folder.
enum MapStore {
    private static var directory: URL { URL.documentsDirectory }
    static var mapURL: URL { directory.appending(path: "venue-map.json") }
    /// Raw RoomPlan output, kept so the floor plan can be rebuilt later with better logic.
    static var roomsURL: URL { directory.appending(path: "captured-rooms.json") }

    static func load() -> VenueMap? {
        guard let data = try? Data(contentsOf: mapURL) else { return nil }
        return try? decoder.decode(VenueMap.self, from: data)
    }

    static func save(_ map: VenueMap, rooms: [CapturedRoom]) throws {
        try encoder.encode(map).write(to: mapURL, options: .atomic)
        try encoder.encode(rooms).write(to: roomsURL, options: .atomic)
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
