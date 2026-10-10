import Foundation

/// Resumable requests for a continuous capture. Each sequence is immutable and safe to resend.
public struct StreamingBackendClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
    }

    @discardableResult
    public func begin(_ manifest: StreamManifest) async throws -> StreamSummary {
        try manifest.validate()
        let response = try await request(path: ["streams"], method: "POST", stage: .upload,
                                         body: JSONEncoder().encode(manifest))
        let summary: StreamSummary = try decode(response)
        try summary.validate(manifest: manifest)
        return summary
    }

    public func summary(id: String) async throws -> StreamSummary {
        try validateStreamID(id)
        let response = try await request(path: ["streams", id], method: "GET", stage: .original)
        let summary: StreamSummary = try decode(response)
        guard summary.id == id, summary.nextSequence >= 0, summary.frameCount == summary.nextSequence else {
            throw BackendClientError.invalidResponse("The scan server acknowledged a different scan.")
        }
        return summary
    }

    @discardableResult
    public func upload(_ chunk: StreamChunk, manifest: StreamManifest) async throws -> StreamSummary {
        try manifest.validate()
        return try await uploadEncodedChunk(chunk.encoded(), sequence: chunk.sequence, manifest: manifest)
    }

    @discardableResult
    public func finish(_ manifest: StreamManifest, chunkCount: Int) async throws -> StreamSummary {
        try manifest.validate()
        guard chunkCount > 0 else { throw StreamingCaptureError.emptyCapture }
        let body = try JSONEncoder().encode(FinishRequest(chunkCount: chunkCount))
        let response = try await request(path: ["streams", manifest.id, "finish"], method: "POST",
                                         stage: .upload, body: body)
        let summary: StreamSummary = try decode(response)
        try summary.validate(manifest: manifest)
        guard summary.finished, summary.nextSequence == chunkCount else {
            throw BackendClientError.invalidResponse("The scan server has not received the complete scan.")
        }
        return summary
    }

    public func scene(id: String) async throws -> ProcessedScene {
        try validateStreamID(id)
        let response = try await request(path: ["streams", id, "scene"], method: "GET", stage: .scene)
        let scene: ProcessedScene = try decode(response)
        do { try scene.validate(expectedScanID: id) }
        catch { throw BackendClientError.invalidResponse(error.localizedDescription) }
        return scene
    }

    public func result(id: String) async throws -> StreamResult {
        try validateStreamID(id)
        let response = try await request(path: ["streams", id, "result"], method: "GET", stage: .scene)
        let result: StreamResult = try decode(response)
        try result.validate(streamID: id)
        return result
    }

    func uploadEncodedChunk(_ data: Data, sequence: Int, manifest: StreamManifest) async throws -> StreamSummary {
        guard sequence >= 0, data.count <= StreamChunk.maximumEncodedBytes else {
            throw StreamingCaptureError.chunkTooLarge
        }
        let response = try await request(path: ["streams", manifest.id, "chunks", String(sequence)],
                                         method: "PUT", stage: .upload, body: data)
        let summary: StreamSummary = try decode(response)
        try summary.validate(manifest: manifest)
        guard summary.nextSequence > sequence else {
            throw BackendClientError.invalidResponse("The scan server did not save this frame.")
        }
        return summary
    }

    private func validateStreamID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw StreamingCaptureError.invalidManifest }
    }

    static func normalizedURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw BackendClientError.invalidURL }
        components.scheme = scheme
        components.host = host.lowercased()
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let normalized = components.url else { throw BackendClientError.invalidURL }
        return normalized
    }

    private func request(path: [String], method: String, stage: BackendRequestStage,
                         body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        let base = try Self.normalizedURL(baseURL)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw BackendClientError.invalidURL
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")
        let segments = try path.map { segment -> String in
            guard !segment.isEmpty, let escaped = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw BackendClientError.invalidURL
            }
            return escaped
        }
        components.percentEncodedPath += "/" + segments.joined(separator: "/")
        guard let url = components.url else { throw BackendClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError { throw BackendClientError.connection(stage: stage, code: error.code) }
        catch { throw BackendClientError.connection(stage: stage, code: .unknown) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse("The scan server returned an invalid response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let details = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error
            throw BackendClientError.http(status: http.statusCode, code: details?.code,
                                          message: details?.message ?? "The scan server could not complete this request (\(http.statusCode)).")
        }
        guard data.count <= 64 * 1024 * 1024 else {
            throw BackendClientError.invalidResponse("The scan server returned a map that is too large.")
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw BackendClientError.invalidResponse("The scan server returned data the app could not read.") }
    }

    private struct FinishRequest: Encodable {
        var chunkCount: Int
        enum CodingKeys: String, CodingKey { case chunkCount = "chunk_count" }
    }
    private struct ErrorEnvelope: Decodable {
        struct Details: Decodable { var code: String; var message: String }
        var error: Details
    }
}
