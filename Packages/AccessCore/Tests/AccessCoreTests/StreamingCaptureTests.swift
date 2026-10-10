import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import AccessCore

private let streamIdentity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func streamFrame(_ timestamp: Double = 1) -> CaptureDepthFrame {
    CaptureDepthFrame(id: UUID().uuidString, timestampSeconds: timestamp, mapFromCamera: streamIdentity,
                      camera: CaptureCameraCalibration(imageWidth: 2, imageHeight: 2, fx: 2, fy: 2, cx: 1, cy: 1),
                      depth: CaptureDepthImage(width: 2, height: 2, valuesM: [1, 1, 1, 1], confidence: [2, 2, 2, 2]))
}

private func streamJPEG() throws -> Data {
    let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func streamRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("inview-stream-test-\(UUID().uuidString)", isDirectory: true)
}

private func streamManifest() -> StreamManifest {
    StreamManifest(id: UUID().uuidString, mapID: "building-1", floorID: "ground")
}

private final class StreamTestServer: @unchecked Sendable {
    enum Reply { case http(Int, Data), failure(URLError.Code), stall }
    struct Record: Sendable { var method: String; var path: String; var body: Data }
    let lock = NSLock()
    private var savedManifest: StreamManifest?
    private var chunks: [Int: Data] = [:]
    private var finished = false
    private var requests: [Record] = []
    private var loseResponse = false
    private var stallUpload = false
    private var stallAll = false
    private var failAll = false
    private var wrongMap = false
    private var rejection: Int?

    var records: [Record] { lock.withLock { requests } }
    var frameCount: Int { lock.withLock { chunks.count } }
    func loseNextUploadResponse() { lock.withLock { loseResponse = true } }
    func stallUploads() { lock.withLock { stallUpload = true } }
    func stallRequests() { lock.withLock { stallAll = true } }
    func failRequests(_ value: Bool) { lock.withLock { failAll = value } }
    func wrongAcknowledgement() { lock.withLock { wrongMap = true } }
    func rejectUploads(status: Int) { lock.withLock { rejection = status } }
    func restart() { lock.withLock { savedManifest = nil; chunks = [:]; finished = false } }

    func reply(to request: URLRequest) throws -> Reply {
        let body = streamRequestBody(request)
        return try lock.withLock {
            let method = request.httpMethod ?? ""
            let path = request.url!.path
            requests.append(Record(method: method, path: path, body: body))
            if stallAll { return .stall }
            if failAll { return .failure(.notConnectedToInternet) }
            var pieces = path.split(separator: "/").map(String.init)
            if pieces.first == "api" { pieces.removeFirst() }
            if method == "POST", pieces == ["streams"] {
                let manifest = try JSONDecoder().decode(StreamManifest.self, from: body)
                if let savedManifest, savedManifest != manifest { return error(409, "stream_conflict") }
                savedManifest = manifest
                return try summary()
            }
            guard let savedManifest, pieces.count >= 2, pieces[0] == "streams", pieces[1] == savedManifest.id else {
                return error(404, "stream_not_found")
            }
            if method == "GET", pieces.count == 2 { return try summary() }
            if method == "PUT", pieces.count == 4, pieces[2] == "chunks", let sequence = Int(pieces[3]) {
                if stallUpload { return .stall }
                if let rejection { return error(rejection, "stream_limit") }
                if let previous = chunks[sequence] {
                    guard previous == body else { return error(409, "stream_chunk_conflict") }
                    return try summary()
                }
                guard !finished, sequence == chunks.count else { return error(409, "stream_sequence_gap") }
                chunks[sequence] = body
                if loseResponse { loseResponse = false; return .failure(.networkConnectionLost) }
                return try summary()
            }
            if method == "POST", pieces.count == 3, pieces[2] == "finish" {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Int]
                guard json?["chunk_count"] == chunks.count, !chunks.isEmpty else { return error(409, "stream_incomplete") }
                finished = true
                return try summary()
            }
            return error(404, "route_not_found")
        }
    }

    private func summary() throws -> Reply {
        let manifest = savedManifest!
        let summary = StreamSummary(id: manifest.id, mapID: wrongMap ? "wrong-map" : manifest.mapID,
                                    floorID: manifest.floorID, nextSequence: chunks.count,
                                    finished: finished, frameCount: chunks.count)
        return .http(200, try JSONEncoder().encode(summary))
    }

    private func error(_ status: Int, _ code: String) -> Reply {
        .http(status, Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"Request failed.\"}}".utf8))
    }
}

private final class StreamMockProtocol: URLProtocol {
    static let lock = NSLock()
    static var servers: [String: StreamTestServer] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host,
              let server = Self.lock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        do {
            switch try server.reply(to: request) {
            case .http(let status, let data):
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                                    cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
            case .stall: return
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func streamServer() -> (StreamTestServer, URL, URLSession) {
    let server = StreamTestServer()
    let host = "stream-\(UUID().uuidString.lowercased()).invalid"
    StreamMockProtocol.lock.withLock { StreamMockProtocol.servers[host] = server }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StreamMockProtocol.self]
    return (server, URL(string: "http://\(host)/api/")!, URLSession(configuration: config))
}

private func streamRequestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func waitForStreamRequest(_ server: StreamTestServer, method: String) async throws {
    for _ in 0..<400 {
        if server.records.contains(where: { $0.method == method }) { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw URLError(.timedOut)
}

struct StreamingCaptureTests {
    @Test func interchangePreservesSynchronizedRGBDepthAndDefaultObservationArrays() throws {
        let chunk = StreamChunk(sequence: 0, frame: streamFrame(), colorJPEG: try streamJPEG())
        let encoded = try chunk.encoded()
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["color_jpeg"] as? String == chunk.colorJPEG.base64EncodedString())
        var withoutOptional = json
        withoutOptional.removeValue(forKey: "surfaces")
        withoutOptional.removeValue(forKey: "objects")
        let decoded = try JSONDecoder().decode(StreamChunk.self, from: JSONSerialization.data(withJSONObject: withoutOptional))
        #expect(decoded == chunk)
        let manifest = streamManifest()
        let manifestJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        #expect(manifestJSON["schema_version"] as? Int == 1)
        #expect(manifestJSON["map_id"] as? String == manifest.mapID)
    }

    @Test func rejectsUnusableCalibrationImagesCoordinatesAndIdentifiers() throws {
        let jpeg = try streamJPEG()
        var frame = streamFrame()
        frame.camera.imageWidth = 4
        #expect(throws: StreamingCaptureError.invalidChunk) {
            try StreamChunk(sequence: 0, frame: frame, colorJPEG: jpeg).validate()
        }
        #expect(throws: StreamingCaptureError.invalidChunk) {
            try StreamChunk(sequence: 0, frame: streamFrame(), colorJPEG: Data("not an image".utf8)).validate()
        }
        #expect(throws: StreamingCaptureError.invalidChunk) {
            try StreamChunk(sequence: 0, frame: streamFrame(), colorJPEG: jpeg.dropLast(8)).validate()
        }
        var missingConfidence = streamFrame()
        missingConfidence.depth.confidence = nil
        #expect(throws: StreamingCaptureError.invalidChunk) {
            try StreamChunk(sequence: 0, frame: missingConfidence, colorJPEG: jpeg).validate()
        }
        for id in ["not-a-uuid", "../escape", ""] {
            #expect(throws: StreamingCaptureError.invalidManifest) { try StreamManifest(id: id, mapID: "map").validate() }
        }
        #expect(throws: StreamingCaptureError.invalidManifest) {
            try StreamManifest(id: UUID().uuidString, mapID: "map/escape").validate()
        }
        #expect(throws: StreamingCaptureError.invalidManifest) {
            try StreamManifest(id: UUID().uuidString, mapID: "map", coordinates: .init(units: "feet", upAxis: "z", handedness: "left")).validate()
        }
    }

    @Test func requestsAreIdempotentAndDifferentContentAtTheSameSequenceConflicts() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        let client = StreamingBackendClient(baseURL: url, session: session)
        let manifest = streamManifest()
        let chunk = StreamChunk(sequence: 0, frame: streamFrame(), colorJPEG: try streamJPEG())
        #expect(try await client.begin(manifest).nextSequence == 0)
        #expect(try await client.upload(chunk, manifest: manifest).nextSequence == 1)
        #expect(try await client.upload(chunk, manifest: manifest).nextSequence == 1)
        var different = chunk
        different.frame.timestampSeconds = 2
        await #expect(throws: BackendClientError.http(status: 409, code: "stream_chunk_conflict", message: "Request failed.")) {
            try await client.upload(different, manifest: manifest)
        }
        let summary = try await client.finish(manifest, chunkCount: 1)
        #expect(summary.finished && summary.frameCount == 1)
        #expect(try await client.finish(manifest, chunkCount: 1) == summary)
        let uploads = server.records.filter { $0.method == "PUT" }
        #expect(uploads[0].body == uploads[1].body)
        #expect(uploads[0].path == "/api/streams/\(manifest.id)/chunks/0")
        #expect(server.frameCount == 1)
    }

    @Test func lostUploadResponseResumesFromServerAcknowledgementWithoutLosingTheOriginal() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        server.loseNextUploadResponse()
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try StreamingCaptureQueue(root: root, manifest: streamManifest(), backendURL: url, session: session)
        await queue.stopUploads()
        try await queue.append(frame: streamFrame(), colorJPEG: streamJPEG())
        await #expect(throws: BackendClientError.connection(stage: .upload, code: .networkConnectionLost)) {
            try await queue.synchronize()
        }
        await queue.stopUploads()
        #expect(await queue.snapshot().uploaded == 0)
        #expect(server.frameCount == 1)
        #expect(try await queue.finish().finished)
        #expect(await queue.snapshot() == StreamingCaptureStatus(captured: 1, uploaded: 1, finished: true))
        #expect(server.records.filter { $0.method == "PUT" }.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("chunks/chunk-0000000000.json").path))
    }

    @Test func reopenAndBackendRestartRestoreAllAcknowledgedFramesFromRetainedFiles() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = streamManifest()
        let jpeg = try streamJPEG()
        let queue = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session)
        await queue.stopUploads()
        for timestamp in 1...3 { try await queue.append(frame: streamFrame(Double(timestamp)), colorJPEG: jpeg) }
        try await queue.synchronize()
        await queue.stopUploads()
        let before = server.records.count
        server.restart()
        let reopened = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session)
        #expect(await reopened.snapshot().uploaded == 3)
        #expect(server.records.count == before)
        #expect(try await reopened.finish().frameCount == 3)
        #expect(server.records.filter { $0.method == "PUT" }.map { $0.path.components(separatedBy: "/").last! } == ["0", "1", "2", "0", "1", "2"])
        #expect(await reopened.snapshot().finished)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("chunks").path).count == 3)
    }

    @Test func appendKeepsSavingABacklogWhileExactlyOneNetworkRequestIsStalled() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        server.stallUploads()
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try StreamingCaptureQueue(root: root, manifest: streamManifest(), backendURL: url, session: session)
        let jpeg = try streamJPEG()
        try await queue.append(frame: streamFrame(), colorJPEG: jpeg)
        try await waitForStreamRequest(server, method: "PUT")
        let start = ContinuousClock.now
        for timestamp in 2...257 { try await queue.append(frame: streamFrame(Double(timestamp)), colorJPEG: jpeg) }
        #expect(start.duration(to: .now) < .seconds(5))
        #expect(await queue.snapshot() == StreamingCaptureStatus(captured: 257, uploaded: 0))
        #expect(server.records.filter { $0.method == "PUT" }.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("chunks").path).count == 257)
        await queue.stopUploads()
        #expect(await queue.snapshot().lastError == nil)
    }

    @Test func failedDiskWriteNeverAcknowledgesOrAdvancesAFrame() async throws {
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try StreamingCaptureQueue(root: root, manifest: streamManifest(), backendURL: nil)
        let chunks = root.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.removeItem(at: chunks)
        try Data("blocked".utf8).write(to: chunks)
        let frame = streamFrame()
        let jpeg = try streamJPEG()
        await #expect(throws: StreamingCaptureError.storageFailure) { try await queue.append(frame: frame, colorJPEG: jpeg) }
        #expect(await queue.snapshot().captured == 0)
        try FileManager.default.removeItem(at: chunks)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        #expect(try await queue.append(frame: frame, colorJPEG: jpeg).captured == 1)
    }

    @Test func reopeningRejectsGapsAndAnotherServerWithoutSendingData() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = streamManifest()
        let queue = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session)
        await queue.stopUploads()
        let jpeg = try streamJPEG()
        for timestamp in 1...3 { try await queue.append(frame: streamFrame(Double(timestamp)), colorJPEG: jpeg) }
        #expect(throws: StreamingCaptureError.backendChanged) {
            try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: URL(string: "http://different.invalid")!, session: session)
        }
        #expect(server.records.isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent("chunks/chunk-0000000001.json"))
        #expect(throws: StreamingCaptureError.missingChunks) {
            try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session)
        }
        #expect(server.records.isEmpty)
    }

    @Test func offlineFinishSealsCaptureAndCanBeRetriedAfterChoosingAServer() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = streamManifest()
        let queue = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: nil, session: session)
        let jpeg = try streamJPEG()
        try await queue.append(frame: streamFrame(), colorJPEG: jpeg)
        await #expect(throws: StreamingCaptureError.notConfigured) { try await queue.finish() }
        let reopened = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: nil, session: session)
        await #expect(throws: StreamingCaptureError.captureClosed) {
            try await reopened.append(frame: streamFrame(2), colorJPEG: jpeg)
        }
        try await reopened.configureBackend(url)
        #expect(try await reopened.finish().finished)
        #expect(server.frameCount == 1)
    }

    @Test func closeCaptureIsDurableOfflineAndNeverStartsNetworking() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = streamManifest()
        let queue = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session)
        await queue.stopUploads()
        try await queue.append(frame: streamFrame(), colorJPEG: streamJPEG())
        #expect(try await queue.closeCapture().captured == 1)
        let reopened = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session)
        await #expect(throws: StreamingCaptureError.captureClosed) {
            try await reopened.append(frame: streamFrame(2), colorJPEG: streamJPEG())
        }
        #expect(server.records.isEmpty)
        #expect(await reopened.snapshot().pending == 1)
    }

    @Test func anAcquiredFrameIsPersistedEvenWhenItsProducerTaskWasCancelled() async throws {
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try StreamingCaptureQueue(root: root, manifest: streamManifest(), backendURL: nil)
        let jpeg = try streamJPEG()
        let task = Task { try await queue.append(frame: streamFrame(), colorJPEG: jpeg) }
        task.cancel()
        #expect(try await task.value.captured == 1)
        #expect(await queue.snapshot().captured == 1)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("chunks/chunk-0000000000.json").path))
    }

    @Test func frameAndByteLimitsKeepTheAcceptedPrefixFinishableAfterReopen() async throws {
        let jpeg = try streamJPEG()
        for frameLimit in [true, false] {
            let (server, url, session) = streamServer()
            defer { session.invalidateAndCancel() }
            let root = streamRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let manifest = streamManifest()
            let first = streamFrame()
            let firstBytes = try StreamChunk(sequence: 0, frame: first, colorJPEG: jpeg).encoded().count
            let limits = StreamingCaptureLimits(maximumFrames: frameLimit ? 1 : 10,
                                                maximumSavedBytes: frameLimit ? 1024 * 1024 : firstBytes)
            let queue = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session, limits: limits)
            await queue.stopUploads()
            try await queue.append(frame: first, colorJPEG: jpeg)
            await #expect(throws: StreamingCaptureError.captureLimit) {
                try await queue.append(frame: streamFrame(2), colorJPEG: jpeg)
            }
            #expect(await queue.snapshot().captured == 1)
            let reopened = try StreamingCaptureQueue(root: root, manifest: manifest, backendURL: url, session: session, limits: limits)
            await #expect(throws: StreamingCaptureError.captureLimit) {
                try await reopened.append(frame: streamFrame(2), colorJPEG: jpeg)
            }
            #expect(try await reopened.finish().frameCount == 1)
            #expect(server.frameCount == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("chunks").path).count == 1)
        }
    }

    @Test func permanentServerRejectionStopsAutomaticAndAppendTriggeredRetries() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        server.rejectUploads(status: 413)
        let root = streamRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try StreamingCaptureQueue(root: root, manifest: streamManifest(), backendURL: url, session: session)
        await queue.stopUploads()
        let jpeg = try streamJPEG()
        try await queue.append(frame: streamFrame(), colorJPEG: jpeg)
        await #expect(throws: BackendClientError.http(status: 413, code: "stream_limit", message: "Request failed.")) {
            try await queue.synchronize()
        }
        try await queue.append(frame: streamFrame(2), colorJPEG: jpeg)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(server.records.filter { $0.method == "PUT" }.count == 1)
        #expect(await queue.snapshot().captured == 2)
        #expect(await queue.snapshot().lastError != nil)
        await queue.stopUploads()
    }

    @Test func rejectsUnexpectedAcknowledgementsAndUnsafeAddresses() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        server.wrongAcknowledgement()
        let manifest = streamManifest()
        let client = StreamingBackendClient(baseURL: url, session: session)
        await #expect(throws: BackendClientError.invalidResponse("The scan server acknowledged a different scan.")) {
            try await client.begin(manifest)
        }
        for value in ["file:///private/tmp/backend", "http://user:password@backend.invalid", "http://backend.invalid?token=private", "http://backend.invalid#fragment"] {
            let invalid = StreamingBackendClient(baseURL: URL(string: value)!, session: session)
            await #expect(throws: BackendClientError.invalidURL) { try await invalid.begin(manifest) }
        }
        #expect(server.records.count == 1)
    }

    @Test func cancellationStopsTransportWithoutBecomingAUserFacingFailure() async throws {
        let (server, url, session) = streamServer()
        defer { session.invalidateAndCancel() }
        server.stallRequests()
        let client = StreamingBackendClient(baseURL: url, session: session)
        let task = Task { try await client.begin(streamManifest()) }
        try await waitForStreamRequest(server, method: "POST")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
