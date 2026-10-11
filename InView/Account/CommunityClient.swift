import AccessCore
import Foundation

struct CommunityAccount: Codable, Identifiable, Equatable {
    let id: UUID
    let email: String
    let name: String?
    let role: String

    var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? email }
    var isAdmin: Bool { role == "admin" }
}

struct CommunityAuthentication: Codable {
    let token: String
    let account: CommunityAccount
}

struct CommunitySubmission: Codable, Identifiable {
    let id: UUID
    let venueID: String
    let floor: Int
    let title: String?
    let status: String
    let revision: Int
    let createdAt: Double
    let updatedAt: Double
    let reviewNote: String?
    let publishedVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, floor, title, status, revision
        case venueID = "venue_id", createdAt = "created_at", updatedAt = "updated_at"
        case reviewNote = "review_note", publishedVersion = "published_version"
    }

    var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "Floor \(floor) scan" }
    var statusTitle: String {
        switch status {
        case "submitted": "Awaiting review"
        case "in_review": "In review"
        case "changes_requested": "Changes requested"
        case "published": "Published"
        default: "Received"
        }
    }
    var statusSymbol: String {
        switch status {
        case "changes_requested": "exclamationmark.bubble"
        case "published": "checkmark.seal"
        case "in_review": "eye"
        default: "clock"
        }
    }
}

enum CommunityError: LocalizedError {
    case notConfigured, invalidAddress, insecureAddress, signedOut, sessionExpired
    case invalidResponse, server(String), keychain
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Accounts and uploads aren’t available yet. Your saved scans stay on this device."
        case .invalidAddress: "The account service address isn’t valid."
        case .insecureAddress: "The account service needs a secure connection."
        case .signedOut: "Sign in to submit a scan."
        case .sessionExpired: "Your session has expired. Sign in again to continue."
        case .invalidResponse: "The service returned an unexpected response. Please try again."
        case .server(let message): message
        case .keychain: "Your sign-in couldn’t be saved securely. Please try again."
        }
    }
}

/// A live service client. An absent address is an unavailable service, never a simulated account.
struct CommunityClient {
    let baseURL: URL
    private let session: URLSession

    static var configuredURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "InViewBackendURL") as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$("), let url = URL(string: value),
              url.host != nil, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    init() throws {
        guard let url = Self.configuredURL else { throw CommunityError.notConfigured }
        try self.init(baseURL: url)
    }

    init(baseURL: URL, session: URLSession = .shared) throws {
        try Self.validateAddress(baseURL)
        self.baseURL = baseURL
        self.session = session
    }

    static func validateAddress(_ url: URL) throws {
        guard let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw CommunityError.invalidAddress }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
        // Passwords and bearer sessions require HTTPS, except a developer's loopback service.
        guard url.scheme == "https" || (url.scheme == "http" && local) else { throw CommunityError.insecureAddress }
    }

    var adminURL: URL { baseURL.appending(path: "admin") }

    func authenticate(email: String, password: String, name: String?, registering: Bool) async throws -> CommunityAuthentication {
        var body = ["email": email, "password": password]
        if registering, let name, !name.isEmpty { body["name"] = name }
        return try await request(registering ? "api/accounts/register" : "api/accounts/login", method: "POST", body: JSONSerialization.data(withJSONObject: body))
    }

    /// Trades the ID token Auth0 issued after Universal Login for this server's own session.
    func authenticateWithAuth0(idToken: String) async throws -> CommunityAuthentication {
        try await request("api/accounts/auth0", method: "POST",
                          body: JSONSerialization.data(withJSONObject: ["id_token": idToken]))
    }

    func account(token: String) async throws -> CommunityAccount {
        try await request("api/accounts/me", token: token)
    }

    func logout(token: String) async throws {
        _ = try await response("api/accounts/logout", method: "POST", token: token)
    }

    // MARK: People

    func discovery(token: String) async throws -> DiscoverySettings {
        try await request("api/accounts/me/discovery", token: token)
    }

    /// `handle` nil leaves it alone; `clearHandle` removes it.
    func setDiscovery(discoverable: Bool? = nil, handle: String? = nil, clearHandle: Bool = false,
                      token: String) async throws -> DiscoverySettings {
        var body: [String: Any] = [:]
        if let discoverable { body["discoverable"] = discoverable }
        if let handle { body["handle"] = handle }
        if clearHandle { body["clear_handle"] = true }
        return try await request("api/accounts/me/discovery", method: "PUT", token: token,
                                 body: JSONSerialization.data(withJSONObject: body))
    }

    /// One person by exact email or handle; throws `CommunityError.server` when nobody can be found.
    func findPerson(_ query: String, token: String) async throws -> PersonMatch {
        try await request("api/people/find", method: "POST", token: token,
                          body: JSONSerialization.data(withJSONObject: ["query": query]))
    }

    /// Which of these contact hashes belong to people who chose to be found.
    func matchContacts(hashes: [String], token: String) async throws -> [PersonMatch] {
        struct Reply: Decodable { var matches: [PersonMatch] }
        let reply: Reply = try await request("api/people/match", method: "POST", token: token,
                                             body: JSONSerialization.data(withJSONObject: ["hashes": hashes]))
        return reply.matches
    }

    // MARK: Live location

    func shares(token: String) async throws -> [PersonShare] {
        struct Reply: Decodable { var shares: [PersonShare] }
        let reply: Reply = try await request("api/people/shares", token: token)
        return reply.shares
    }

    /// `offer`: you let them see you. `request`: you ask to see them (they must accept).
    func startShare(personID: String, offering: Bool, minutes: Int = 60, token: String) async throws -> PersonShare {
        try await request("api/people/shares", method: "POST", token: token,
                          body: JSONSerialization.data(withJSONObject: [
                              "person_id": personID, "mode": offering ? "offer" : "request", "minutes": minutes] as [String: Any]))
    }

    func respondToShare(id: String, accept: Bool, minutes: Int = 60, token: String) async throws -> PersonShare {
        try await request("api/people/shares/\(id)/respond", method: "POST", token: token,
                          body: JSONSerialization.data(withJSONObject: ["accept": accept, "minutes": minutes] as [String: Any]))
    }

    func endShare(id: String, token: String) async throws {
        _ = try await response("api/people/shares/\(id)", method: "DELETE", token: token)
    }

    /// Whether the server kept it: false means nobody can currently see your position.
    @discardableResult
    func publish(_ position: SharedPosition, token: String) async throws -> Bool {
        struct Reply: Decodable { var shared: Bool }
        let reply: Reply = try await request("api/accounts/me/position", method: "PUT", token: token,
                                             body: JSONEncoder().encode(position))
        return reply.shared
    }

    func location(of personID: String, token: String) async throws -> PersonLocation {
        try await request("api/people/\(personID)/location", token: token)
    }

    func submissions(token: String) async throws -> [CommunitySubmission] {
        try await request("api/submissions", token: token)
    }

    func upload(_ draft: ContributionDraft, mapData: Data, token: String) async throws -> CommunitySubmission {
        let map = try JSONSerialization.jsonObject(with: mapData)
        var body: [String: Any] = [
            "client_submission_id": draft.id.uuidString,
            "map": map,
            "notes": draft.notes,
            "authorized_space": true
        ]
        let path: String
        if let submissionID = draft.submissionID, let expectedRevision = draft.expectedRevision {
            path = "api/submissions/\(submissionID.uuidString)/resubmit"
            body["expected_revision"] = expectedRevision
        } else {
            path = "api/submissions"
            body["venue_id"] = "student-center-east"
            body["floor"] = draft.floor
            body["title"] = draft.title
        }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        guard encoded.count <= 2 * 1_024 * 1_024 else {
            throw CommunityError.server("This floor map is too large. Choose a smaller file.")
        }
        return try await request(path, method: "POST", token: token, body: encoded)
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> T {
        let data = try await response(path, method: method, token: token, body: body)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CommunityError.invalidResponse }
    }

    private func response(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CommunityError.invalidResponse }
        if path == "api/accounts/auth0" {
            switch response.statusCode {
            case 200..<300: return data
            case 401: throw CommunityError.server("We couldn’t verify that sign-in. Please try again.")
            case 404: throw CommunityError.server("Sign-in with Apple or email isn’t available on this server yet.")
            case 409: throw CommunityError.server("This email already belongs to a different sign-in method.")
            case 429: throw CommunityError.server("Too many attempts. Wait a moment and try again.")
            default: throw CommunityError.server("Sign-in is unavailable right now. Please try again later.")
            }
        }
        if path.hasPrefix("api/people") || path == "api/accounts/me/discovery" {
            switch response.statusCode {
            case 200..<300: return data
            case 401: throw CommunityError.sessionExpired
            case 404 where path.hasSuffix("/location"):
                throw CommunityError.server("They aren’t sharing a live position right now.")
            case 404 where path.hasPrefix("api/people/shares"):
                throw CommunityError.server("That location share has ended.")
            case 404: throw CommunityError.server("No one with that email or handle is available to find.")
            case 409 where path.hasPrefix("api/people/shares"):
                throw CommunityError.server("End a location share before starting another.")
            case 409: throw CommunityError.server("That handle is already in use. Try another.")
            case 422, 400: throw CommunityError.server("Use 3 to 24 letters, numbers, dots or underscores for a handle.")
            case 429: throw CommunityError.server("You’ve searched a lot. Wait a few minutes and try again.")
            default: throw CommunityError.server("People search is unavailable right now.")
            }
        }
        switch response.statusCode {
        case 200..<300: return data
        case 401: throw token == nil ? CommunityError.server("The email or password is incorrect.") : CommunityError.sessionExpired
        case 403: throw CommunityError.server("This account doesn’t have permission for that action.")
        case 409: throw CommunityError.server("This scan or account has changed. Refresh and try again.")
        case 413: throw CommunityError.server("This file is too large. Choose a smaller floor map.")
        case 422, 400: throw CommunityError.server("Check your details and scan file, then try again.")
        case 429: throw CommunityError.server("Too many attempts. Wait a moment and try again.")
        default: throw CommunityError.server("The service is unavailable. Please try again later.")
        }
    }
}
