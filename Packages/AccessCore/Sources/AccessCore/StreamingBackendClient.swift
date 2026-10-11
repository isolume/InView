import Foundation
import zlib

/// Resumable requests for a continuous capture. Each sequence is immutable and safe to resend.
public struct StreamingBackendClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    /// Bearer token for an authenticated backend. Sent only over HTTPS or to a loopback host.
    private let accessToken: String?

    public init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
        self.accessToken = accessToken.flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    public func begin(_ manifest: StreamManifest) async throws -> StreamSummary {
        try await beginSession(manifest).summary
    }

    /// Transport capabilities are negotiated for this server, so older servers keep using JSON.
    func beginSession(_ manifest: StreamManifest) async throws -> (summary: StreamSummary, acceptsGzip: Bool) {
        try manifest.validate()
        let response: Response
        do {
            response = try await request(path: ["streams"], method: "POST", stage: .upload,
                                         body: JSONEncoder().encode(manifest))
        } catch BackendClientError.http(status: 404, code: "not_found"?, message: _) {
            // The server answers but has no stream routes: a deployment older than continuous capture.
            throw BackendClientError.http(
                status: 404, code: "streams_unsupported",
                message: "This scan server is out of date and can't receive scans. Update it, then resume from Settings › Saved scans.")
        }
        let summary: StreamSummary = try decode(response)
        try summary.validate(manifest: manifest)
        return (summary, response.acceptsGzip)
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

    /// Uploads a whole-capture attachment (`StreamAttachment.allowedNames`) for this stream.
    public func putAttachment(_ data: Data, named name: String, manifest: StreamManifest) async throws {
        try manifest.validate()
        guard StreamAttachment.allowedNames.contains(name), data.count <= StreamAttachment.maximumBytes else {
            throw StreamingCaptureError.invalidChunk
        }
        _ = try await request(path: ["streams", manifest.id, "assets", name], method: "PUT", stage: .upload, body: data)
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
        let response = try await resultResponse(id: id)
        let result: StreamResult = try decode(response)
        try result.validate(streamID: id)
        return result
    }

    public func result(manifest: StreamManifest) async throws -> StreamResult {
        try manifest.validate()
        let response = try await resultResponse(id: manifest.id)
        let result: StreamResult = try decode(response)
        try result.validate(manifest: manifest)
        return result
    }

    /// Recognition can finish shortly after capture. Keep that normal wait within the existing
    /// result deadline, without retrying unavailable providers or other server failures.
    private func resultResponse(id: String) async throws -> Response {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(180))
        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask { try await pollForResult(id: id, deadline: deadline) }
            group.addTask {
                try await clock.sleep(until: deadline)
                throw BackendClientError.connection(stage: .scene, code: .timedOut)
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    private func pollForResult(id: String, deadline: ContinuousClock.Instant) async throws -> Response {
        let clock = ContinuousClock()
        var delay = Duration.seconds(1)
        while true {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw BackendClientError.connection(stage: .scene, code: .timedOut)
            }
            let components = remaining.components
            let timeout = Double(components.seconds) + Double(components.attoseconds) / 1e18
            do {
                return try await request(path: ["streams", id, "result"], method: "GET", stage: .scene,
                                         timeoutInterval: timeout)
            } catch let error as BackendClientError {
                guard case .http(status: 503, code: let code, message: _) = error,
                      code == "recognition_pending" || code == "processing_busy" else { throw error }
                guard clock.now.advanced(by: delay) < deadline else { throw error }
                try await Task.sleep(for: delay)
                delay = .seconds(2)
            }
        }
    }

    func uploadEncodedChunk(_ data: Data, sequence: Int, manifest: StreamManifest, acceptsGzip: Bool = false) async throws -> StreamSummary {
        guard sequence >= 0, data.count <= StreamChunk.maximumEncodedBytes else {
            throw StreamingCaptureError.chunkTooLarge
        }
        // Numeric depth arrays compress well without changing a single measurement. Keep all
        // compression work off the queue actor and fall back when it does not save bandwidth.
        let compressed = acceptsGzip ? await Task.detached(priority: .utility) { Self.gzipIfSmaller(data) }.value : nil
        try Task.checkCancellation()
        let response = try await request(path: ["streams", manifest.id, "chunks", String(sequence)],
                                         method: "PUT", stage: .upload, body: compressed ?? data,
                                         contentEncoding: compressed == nil ? nil : "gzip")
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

    private struct Response: Sendable {
        var data: Data
        var acceptsGzip: Bool
    }

    private func request(path: [String], method: String, stage: BackendRequestStage,
                         body: Data? = nil, contentEncoding: String? = nil,
                         timeoutInterval: TimeInterval? = nil) async throws -> Response {
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
        if accessToken != nil, url.scheme != "https",
           !["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") {
            throw BackendClientError.invalidURL  // Never send a credential in clear text.
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        // Large models can take longer than an upload request to reconstruct. Keep the
        // transport cancellable while allowing a bounded wait for the finished result.
        request.timeoutInterval = timeoutInterval ?? (stage == .scene ? 180 : 45)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let contentEncoding { request.setValue(contentEncoding, forHTTPHeaderField: "Content-Encoding") }
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
        let encodings = http.value(forHTTPHeaderField: "Accept-Encoding")?.lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return Response(data: data, acceptsGzip: encodings.contains("gzip"))
    }

    private func decode<T: Decodable>(_ response: Response) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: response.data) }
        catch { throw BackendClientError.invalidResponse("The scan server returned data the app could not read.") }
    }

    /// Bounded output: if gzip cannot fit in less space than the original, use the original.
    static func gzipIfSmaller(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= StreamChunk.maximumEncodedBytes else { return nil }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16,
                           MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                           Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data(count: data.count)
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = target.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(target.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0, Int(stream.total_out) < data.count else { return nil }
        output.removeSubrange(Int(stream.total_out)..<output.count)
        return output
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
