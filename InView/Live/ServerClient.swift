import AccessCore
import Foundation

/// Live state of an access point, as reported by the mapping crew through the iMessage agent.
struct PointStatus: Codable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case operational
        case outOfService = "out_of_service"
    }

    let pointId: UUID
    let state: State
    let note: String?
    let reportedAt: Date
    /// Whether a photo with the report backed it up.
    let photoVerified: Bool
}

/// Talks to the InView server: uploads the scanned venue and reads live point status.
struct ServerClient {
    private let baseURL: URL

    /// Nil when no server is configured; the app then works offline.
    init?() {
        guard let baseURL = AppConfig.serverURL else { return nil }
        self.baseURL = baseURL
    }

    func uploadVenue(_ map: VenueMap, report: AccessibilityReport) async throws {
        struct Upload: Encodable {
            let map: VenueMap
            let report: AccessibilityReport
        }
        var request = URLRequest(url: baseURL.appending(path: "api/venue"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(Upload(map: map, report: report))
        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
    }

    func statuses() async throws -> [PointStatus] {
        struct Payload: Decodable { let statuses: [PointStatus] }
        var request = URLRequest(url: baseURL.appending(path: "api/status"))
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        return try Self.decoder.decode(Payload.self, from: data).statuses
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            // JavaScript's toISOString() includes milliseconds, which .iso8601 rejects.
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
                return date
            }
            return try Date(string, strategy: .iso8601)
        }
        return decoder
    }()
}
