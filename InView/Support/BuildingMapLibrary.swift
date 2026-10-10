import AccessCore
import Foundation
import SwiftUI

/// Reviewed releases are cached separately from private captures and from the bundled starter scan.
@MainActor
final class BuildingMapLibrary: ObservableObject {
    struct Release: Decodable, Identifiable {
        let id: UUID
        let floor: Int
        let version: UInt64
        let mapRevision: UInt64
        let publishedAt: Double
        let origin: String
        let map: VenueMap
        enum CodingKeys: String, CodingKey {
            case id, floor, version, origin, map
            case mapRevision = "map_revision", publishedAt = "published_at"
        }
    }
    private struct Envelope: Decodable {
        let venueID: String
        let maps: [Release]
        enum CodingKeys: String, CodingKey { case venueID = "venue_id", maps }
    }
    private struct Cache: Codable {
        let address: String
        let data: Data
    }
    @Published private(set) var releases: [Release] = []
    @Published private(set) var message: String?
    @Published private(set) var isRefreshing = false
    private let cacheURL = URL.documentsDirectory.appending(path: "student-center-published-maps.json")

    init() {
        guard let url = CommunityClient.configuredURL, (try? CommunityClient.validateAddress(url)) != nil,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.address == url.absoluteString,
              let envelope = try? Self.decode(cache.data) else { return }
        releases = envelope.maps
    }

    func release(for floor: Int) -> Release? { releases.first { $0.floor == floor } }
    func isReviewed(floor: Int) -> Bool { release(for: floor) != nil }

    func refresh() async {
        guard !isRefreshing, let url = CommunityClient.configuredURL else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try CommunityClient.validateAddress(url)
            var request = URLRequest(url: url.appending(path: "api/venues/student-center-east/maps"))
            request.timeoutInterval = 12
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CommunityError.invalidResponse }
            let envelope = try Self.decode(data)
            let cache = Cache(address: url.absoluteString, data: data)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
            releases = envelope.maps
            message = nil
        } catch {
            message = releases.isEmpty ? "Couldn’t check for map updates. The included scan is available offline." : "Couldn’t check for updates. Showing the last downloaded maps."
        }
    }

    private static func decode(_ data: Data) throws -> Envelope {
        guard data.count <= 8_000_000 else { throw CommunityError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.venueID == "student-center-east", envelope.maps.count <= 3,
              Set(envelope.maps.map(\.floor)).count == envelope.maps.count,
              envelope.maps.allSatisfy({ (1...3).contains($0.floor) && $0.version > 0 && $0.mapRevision > 0
                  && $0.origin == "admin_reviewed" && $0.publishedAt.isFinite && StudentCenterCatalog.isDisplayable($0.map) }) else {
            throw CommunityError.invalidResponse
        }
        return envelope
    }
}
