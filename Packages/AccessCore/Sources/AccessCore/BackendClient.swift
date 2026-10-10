import Foundation

public struct CaptureUploadSummary: Codable, Equatable, Sendable {
    public var id: String
    public var mapID: String
    public var floorID: String
    public var meshCount: Int
    public var frameCount: Int
    public var objectCount: Int
    public var surfaceCount: Int
    public init(id: String, mapID: String, floorID: String, meshCount: Int, frameCount: Int, objectCount: Int, surfaceCount: Int) {
        self.id = id; self.mapID = mapID; self.floorID = floorID; self.meshCount = meshCount
        self.frameCount = frameCount; self.objectCount = objectCount; self.surfaceCount = surfaceCount
    }
    enum CodingKeys: String, CodingKey {
        case id, mapID = "map_id", floorID = "floor_id", meshCount = "mesh_count", frameCount = "frame_count"
        case objectCount = "object_count", surfaceCount = "surface_count"
    }
}

public enum BackendRequestStage: Equatable, Sendable {
    case upload, original, scene, health
}

public enum BackendClientError: Error, LocalizedError, Equatable {
    case invalidURL
    case invalidCapture(String)
    case connection(stage: BackendRequestStage, code: URLError.Code)
    case http(status: Int, code: String?, message: String)
    case invalidResponse(String)
    case captureConflict

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a backend address beginning with http:// or https://."
        case .invalidCapture(let message): return message
        case .connection(let stage, let code):
            switch code {
            case .timedOut:
                switch stage {
                case .upload: return "Sending the scan took too long. Check your connection and try again."
                case .original: return "Checking the saved scan took too long. Try again."
                case .scene: return "The 3D map took too long to respond. Try again."
                case .health: return "The scan server took too long to respond. Check its address and your connection."
                }
            case .cannotFindHost: return "Could not find the scan server. Check its address."
            case .notConnectedToInternet: return "Could not connect to the scan server. Check your connection."
            case .networkConnectionLost: return "The connection to the scan server was lost. Try again."
            case .appTransportSecurityRequiresSecureConnection:
                return "Use a secure address for the scan server."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "Could not make a secure connection to the scan server. Check its address."
            default: return "Could not connect to the scan server. Check its address and your connection."
            }
        case .http(_, "processing_failed", _): return "The scan server could not build the 3D map. Try again."
        case .http(_, _, let message): return message
        case .invalidResponse(let message): return message
        case .captureConflict: return "A different capture already uses this identifier. Your saved scan has been kept."
        }
    }

    var isMissingCapture: Bool {
        if case .http(status: 404, code: "scan_not_found", message: _) = self { return true }
        return false
    }
    var isExistingCapture: Bool {
        if case .http(status: 409, code: "scan_exists", message: _) = self { return true }
        return false
    }
}

/// Uploads an immutable draft capture and retrieves verified geometry for a native preview.
public struct BackendClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
    }

    /// Checks the configured server without sending a capture or starting processing.
    public func checkHealth() async throws {
        let response = try await request(path: ["health"], method: "GET", stage: .health, timeout: 5)
        guard let health = try? JSONDecoder().decode(BackendHealthResponse.self, from: response),
              health.status == "ok", health.service == "inview-backend" else {
            throw BackendClientError.invalidResponse("This address is not a ready InView scan server.")
        }
    }

    /// A duplicate is usable only when the stored source matches this exact upload.
    @discardableResult
    public func upload(_ capture: CaptureBundle) async throws -> CaptureUploadSummary {
        try validateCapture(capture)
        let data: Data
        do { data = try JSONEncoder().encode(capture) }
        catch { throw BackendClientError.invalidCapture("The capture could not be prepared for upload.") }
        do {
            let response = try await request(path: ["scans"], method: "POST", stage: .upload, body: data)
            let summary: CaptureUploadSummary = try decode(response)
            let expected = capture.summary
            guard summary == expected else {
                throw BackendClientError.invalidResponse("The backend acknowledged a different capture.")
            }
            return summary
        } catch let error as BackendClientError where error.isExistingCapture {
            try await verifyOriginal(capture, encoded: data)
            return capture.summary
        }
    }

    /// Fetches an already uploaded scene. Use process(capture) to recover from a backend restart.
    public func scene(scanID: String) async throws -> ProcessedScene {
        let response = try await request(path: ["scans", scanID, "scene"], method: "GET", stage: .scene)
        let scene: ProcessedScene = try decode(response)
        do { try scene.validate(expectedScanID: scanID) }
        catch { throw BackendClientError.invalidResponse(error.localizedDescription) }
        return scene
    }

    /// Reuses a matching remote capture or restores the locally saved capture after a restart.
    public func process(_ capture: CaptureBundle) async throws -> ProcessedScene {
        try validateCapture(capture)
        do {
            let result = try await verifiedScene(capture)
            try await verifyOriginal(capture)
            return result
        } catch let error as BackendClientError where error.isMissingCapture {
            return try await uploadAndProcess(capture)
        }
    }

    public func uploadAndProcess(_ capture: CaptureBundle) async throws -> ProcessedScene {
        try await upload(capture)
        do { return try await verifiedScene(capture) }
        catch let error as BackendClientError where error.isMissingCapture {
            // The prototype store is in memory. A restart between requests needs one reupload.
            try await upload(capture)
            return try await verifiedScene(capture)
        }
    }

    private func verifiedScene(_ capture: CaptureBundle) async throws -> ProcessedScene {
        let result = try await scene(scanID: capture.id)
        do { try result.validate(source: capture) }
        catch { throw BackendClientError.invalidResponse(error.localizedDescription) }
        return result
    }

    private func verifyOriginal(_ capture: CaptureBundle, encoded: Data? = nil) async throws {
        let original = try await request(path: ["scans", capture.id], method: "GET", stage: .original)
        let serverJSON: JSONValue = try decode(original)
        let localData = try encoded ?? JSONEncoder().encode(capture)
        let localJSON: JSONValue = try decode(localData)
        guard serverJSON == localJSON else { throw BackendClientError.captureConflict }
    }

    private func validateCapture(_ capture: CaptureBundle) throws {
        do { try capture.validate() }
        catch { throw BackendClientError.invalidCapture(error.localizedDescription) }
    }

    private func request(path: [String], method: String, stage: BackendRequestStage,
                         timeout: TimeInterval = 45, body: Data? = nil) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw BackendClientError.invalidURL }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let segments = try path.map { segment -> String in
            guard !segment.isEmpty, let escaped = segment.addingPercentEncoding(withAllowedCharacters: safeCharacters)
            else { throw BackendClientError.invalidURL }
            return escaped
        }
        components.percentEncodedPath = basePath + "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw BackendClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError { throw BackendClientError.connection(stage: stage, code: error.code) }
        catch { throw BackendClientError.connection(stage: stage, code: .unknown) }
        guard let response = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse("The backend returned an invalid response.")
        }
        guard (200...299).contains(response.statusCode) else {
            let details = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data).error
            throw BackendClientError.http(status: response.statusCode, code: details?.code,
                                          message: details?.message ?? "The backend could not complete this request (\(response.statusCode)).")
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw BackendClientError.invalidResponse("The backend returned a scene that is too large.")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw BackendClientError.invalidResponse("The backend returned data the app could not read.") }
    }
}

private struct BackendHealthResponse: Decodable {
    var status: String
    var service: String
}

private struct BackendErrorEnvelope: Decodable {
    struct Details: Decodable { var code: String; var message: String }
    var error: Details
}

private extension CaptureBundle {
    var summary: CaptureUploadSummary {
        CaptureUploadSummary(id: id, mapID: mapID, floorID: floorID, meshCount: meshes.count,
                             frameCount: frames.count, objectCount: objects.count, surfaceCount: surfaces.count)
    }
}
