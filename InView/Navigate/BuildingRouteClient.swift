import AccessCore
import Foundation

enum BuildingRouteClientError: Error, LocalizedError {
    case notConfigured, invalidAddress, unavailable, graphUnavailable, noRoute(RoutePreference), invalidResponse
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Building directions aren’t available yet. You can still explore the floor maps."
        case .invalidAddress: "The directions service address isn’t valid."
        case .unavailable: "Couldn’t reach the directions service. Please try again."
        case .graphUnavailable: "Connections between floors haven’t been added for this building yet."
        case .noRoute(let preference): preference == .stepFree
            ? "No step-free route connects these places with the current map and conditions."
            : "No available route connects these places with the current map and conditions."
        case .invalidResponse: "The directions could not be read. Refresh the building and try again."
        }
    }
}

/// Building routing uses the server's mapped connections and time-based search. This client does not
/// synthesize connections from floor illustrations or draw a connector through unrelated map frames.
struct BuildingRouteClient {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    let baseURL: URL
    private let session: URLSession

    init() throws {
        guard let url = CommunityClient.configuredURL else { throw BuildingRouteClientError.notConfigured }
        try self.init(baseURL: url)
    }

    init(baseURL: URL, session: URLSession = .shared) throws {
        let host = baseURL.host?.lowercased()
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host?.hasSuffix(".local") == true
        guard host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.scheme?.lowercased() == "https" || (baseURL.scheme?.lowercased() == "http" && local) else {
            throw BuildingRouteClientError.invalidAddress
        }
        self.baseURL = baseURL; self.session = session
    }

    func loadGraph(graphID: String, venueID: String, allowDemo: Bool = false) async throws -> BuildingRouteGraph {
        guard Self.validPathID(graphID), graphID == venueID || allowDemo else { throw BuildingRouteError.wrongBuilding }
        #if !DEBUG
        guard !allowDemo else { throw BuildingRouteError.demoGraph }
        #endif
        let data = try await response(path: ["graphs", graphID])
        let graph: BuildingRouteGraph
        do { graph = try JSONDecoder().decode(BuildingRouteGraph.self, from: data) }
        catch { throw BuildingRouteClientError.invalidResponse }
        try graph.validate(expectedGraphID: graphID, venueID: venueID, allowDemo: allowDemo)
        return graph
    }

    func route(graph: BuildingRouteGraph, from: String, to: String, preference: RoutePreference) async throws -> BuildingRoute {
        guard Self.validPathID(graph.id), let venueID = graph.venueID else { throw BuildingRouteError.wrongBuilding }
        #if DEBUG
        let allowDemo = graph.isDemo
        #else
        let allowDemo = false
        #endif
        guard graph.id == venueID || allowDemo else { throw BuildingRouteError.wrongBuilding }
        try graph.validate(expectedGraphID: graph.id, venueID: venueID, allowDemo: allowDemo)
        let request = BuildingRouteRequest(from: from, to: to, preference: preference)
        try request.validate(graph: graph)
        let data = try await response(path: ["graphs", graph.id, "routes"], body: JSONEncoder().encode(request), preference: preference)
        let route: BuildingRoute
        do { route = try JSONDecoder().decode(BuildingRoute.self, from: data) }
        catch { throw BuildingRouteClientError.invalidResponse }
        try route.validate(graph: graph, request: request)
        return route
    }

    private func response(path: [String], body: Data? = nil, preference: RoutePreference? = nil) async throws -> Data {
        let url = path.reduce(baseURL) { $0.appendingPathComponent($1) }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let http: HTTPURLResponse
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw BuildingRouteClientError.invalidResponse }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw BuildingRouteClientError.invalidResponse }
            http = response
            var bounded = Data()
            for try await byte in bytes {
                guard bounded.count < Self.maximumResponseBytes else { throw BuildingRouteClientError.invalidResponse }
                bounded.append(byte)
            }
            data = bounded
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as BuildingRouteClientError { throw error }
        catch { throw BuildingRouteClientError.unavailable }
        switch http.statusCode {
        case 200: return data
        case 404: throw BuildingRouteClientError.graphUnavailable
        case 422:
            struct Envelope: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            if let preference, (try? JSONDecoder().decode(Envelope.self, from: data).error.code) == "no_verified_route" {
                throw BuildingRouteClientError.noRoute(preference)
            }
            throw BuildingRouteClientError.invalidResponse
        default: throw BuildingRouteClientError.unavailable
        }
    }

    private static func validPathID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id != "." && id != ".."
            && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
}
