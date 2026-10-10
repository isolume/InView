import Foundation

/// Budgets can be reduced for a device or test, but cannot exceed the server's hard limits.
public struct StreamingCaptureLimits: Equatable, Sendable {
    public static let standard = StreamingCaptureLimits()
    public var maximumFrames: Int
    public var maximumSavedBytes: Int

    public init(maximumFrames: Int = 10_000, maximumSavedBytes: Int = 2 * 1024 * 1024 * 1024) {
        self.maximumFrames = maximumFrames; self.maximumSavedBytes = maximumSavedBytes
    }
}

public struct StreamingCaptureStatus: Equatable, Sendable {
    public var captured: Int
    public var uploaded: Int
    public var pending: Int { max(0, captured - uploaded) }
    public var lastError: String?
    /// True only after the server acknowledges the complete capture.
    public var finished: Bool

    public init(captured: Int, uploaded: Int, lastError: String? = nil, finished: Bool = false) {
        self.captured = captured; self.uploaded = uploaded
        self.lastError = lastError; self.finished = finished
    }
}

/// Saves every accepted frame before scheduling network work. Only one chunk is read for upload
/// at a time, regardless of backlog size, and acknowledged originals remain on disk for recovery.
public actor StreamingCaptureQueue {
    public nonisolated let root: URL
    public nonisolated let manifest: StreamManifest
    private let session: URLSession
    private let limits: StreamingCaptureLimits
    private var state: Checkpoint
    private var captured: Int
    private var capturedBytes: Int
    private var lastTimestamp: Double?
    private var lastError: String?
    private var uploadTask: Task<Void, Error>?
    private var uploadID: UUID?
    private var retryTask: Task<Void, Never>?
    private var retryAttempts = 0
    private var uploadsPaused = false
    private var permanentUploadFailure = false
    private var finishTask: Task<StreamSummary, Error>?

    /// Reopening restores saved progress but does not send anything until append/synchronize/finish.
    /// A saved server binding must match an explicitly supplied address; changing it is a separate action.
    public init(root: URL, manifest: StreamManifest, backendURL: URL?, session: URLSession = .shared,
                limits: StreamingCaptureLimits = .standard) throws {
        try manifest.validate()
        guard limits.maximumFrames > 0, limits.maximumFrames <= StreamingCaptureLimits.standard.maximumFrames,
              limits.maximumSavedBytes > 0, limits.maximumSavedBytes <= StreamingCaptureLimits.standard.maximumSavedBytes else {
            throw StreamingCaptureError.invalidLimits
        }
        guard root.isFileURL else { throw StreamingCaptureError.storageFailure }
        self.root = root; self.manifest = manifest; self.session = session; self.limits = limits
        let suppliedURL = try backendURL.map(StreamingBackendClient.normalizedURL)
        let manager = FileManager.default
        let manifestURL = root.appendingPathComponent("manifest.json")
        let checkpointURL = root.appendingPathComponent("checkpoint.json")
        let chunksURL = root.appendingPathComponent("chunks", isDirectory: true)
        let totals = try Self.savedChunkTotals(at: chunksURL)
        let count = totals.count
        guard count <= StreamingCaptureLimits.standard.maximumFrames,
              totals.bytes <= StreamingCaptureLimits.standard.maximumSavedBytes else { throw StreamingCaptureError.captureLimit }
        if manager.fileExists(atPath: manifestURL.path) {
            let original: StreamManifest = try Self.readJSON(from: manifestURL)
            guard original == manifest else { throw StreamingCaptureError.localConflict }
        } else {
            guard count == 0, !manager.fileExists(atPath: checkpointURL.path) else {
                throw StreamingCaptureError.localConflict
            }
            do { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
            catch { throw StreamingCaptureError.storageFailure }
            try Self.writeJSON(manifest, to: manifestURL)
        }
        var checkpoint: Checkpoint
        if manager.fileExists(atPath: checkpointURL.path) {
            checkpoint = try Self.readJSON(from: checkpointURL)
        } else {
            checkpoint = Checkpoint(backendURL: suppliedURL?.absoluteString)
        }
        if let savedAddress = checkpoint.backendURL {
            guard let savedURL = URL(string: savedAddress) else { throw StreamingCaptureError.localConflict }
            let normalized = try StreamingBackendClient.normalizedURL(savedURL)
            guard suppliedURL == nil || suppliedURL == normalized else { throw StreamingCaptureError.backendChanged }
            checkpoint.backendURL = normalized.absoluteString
        } else {
            checkpoint.backendURL = suppliedURL?.absoluteString
        }
        guard checkpoint.uploaded >= 0, checkpoint.uploaded <= count,
              !checkpoint.finished || (checkpoint.captureClosed && checkpoint.uploaded == count) else {
            throw StreamingCaptureError.missingChunks
        }
        do { try manager.createDirectory(at: chunksURL, withIntermediateDirectories: true) }
        catch { throw StreamingCaptureError.storageFailure }
        try Self.writeJSON(checkpoint, to: checkpointURL)
        self.state = checkpoint
        self.captured = count
        self.capturedBytes = totals.bytes
        if count > 0 {
            let last: StreamChunk = try Self.readChunk(from: Self.chunkURL(root: root, sequence: count - 1))
            guard last.sequence == count - 1 else { throw StreamingCaptureError.missingChunks }
            try last.validate()
            self.lastTimestamp = last.frame.timestampSeconds
        }
    }

    @discardableResult
    public func append(frame: CaptureDepthFrame, colorJPEG: Data,
                       surfaces: [CaptureSurface] = [], objects: [CaptureObject] = []) async throws -> StreamingCaptureStatus {
        guard !state.captureClosed else { throw StreamingCaptureError.captureClosed }
        guard captured < limits.maximumFrames else { throw StreamingCaptureError.captureLimit }
        guard lastTimestamp == nil || frame.timestampSeconds > lastTimestamp! else {
            throw StreamingCaptureError.invalidChunk
        }
        let chunk = StreamChunk(sequence: captured, frame: frame, colorJPEG: colorJPEG,
                                surfaces: surfaces, objects: objects)
        let data = try chunk.encoded()
        guard data.count <= limits.maximumSavedBytes - min(capturedBytes, limits.maximumSavedBytes) else {
            throw StreamingCaptureError.captureLimit
        }
        // Do not consult task cancellation after a frame has been accepted: an in-flight sample
        // acquired before pause still needs to be saved. This transaction has no suspension points.
        do { try data.write(to: Self.chunkURL(root: root, sequence: captured), options: .atomic) }
        catch { throw StreamingCaptureError.storageFailure }
        captured += 1
        capturedBytes += data.count
        lastTimestamp = frame.timestampSeconds
        if !uploadsPaused, !permanentUploadFailure, state.backendURL != nil, uploadTask == nil, retryTask == nil { startWorker() }
        return snapshot()
    }

    public func snapshot() -> StreamingCaptureStatus {
        StreamingCaptureStatus(captured: captured, uploaded: state.uploaded,
                               lastError: lastError, finished: state.finished)
    }

    /// Durably end capture without requiring a connection or starting an upload.
    @discardableResult
    public func closeCapture() throws -> StreamingCaptureStatus {
        if !state.captureClosed {
            var next = state
            next.captureClosed = true
            try save(next)
        }
        retryTask?.cancel(); retryTask = nil
        return snapshot()
    }

    /// Retries against the manifest acknowledgement, including rollback after a backend restart.
    public func synchronize() async throws {
        guard state.backendURL != nil else { throw StreamingCaptureError.notConfigured }
        uploadsPaused = false
        permanentUploadFailure = false
        retryTask?.cancel(); retryTask = nil
        let task = uploadTask ?? startWorker()
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.stopUploads() }
        }
    }

    /// Closing capture is durable even when the network is down; finish can then be retried.
    public func finish() async throws -> StreamSummary {
        guard captured > 0 else { throw StreamingCaptureError.emptyCapture }
        if let finishTask { return try await finishTask.value }
        try closeCapture()
        let task = Task { try await self.finalize() }
        finishTask = task
        return try await withTaskCancellationHandler {
            let summary = try await task.value
            try Task.checkCancellation()
            return summary
        } onCancel: {
            task.cancel()
            Task { await self.stopUploads() }
        }
    }

    public func result() async throws -> StreamResult {
        guard state.finished else {
            throw BackendClientError.invalidResponse("Finish sending this scan before opening its map.")
        }
        let result = try await client().result(id: manifest.id)
        try result.validate(manifest: manifest)
        return result
    }

    /// Cancel transport and retries while retaining every frame, including pending frames.
    public func stopUploads() async {
        uploadsPaused = true
        retryTask?.cancel(); retryTask = nil
        let active = uploadTask
        let finishing = finishTask
        finishing?.cancel()
        active?.cancel()
        _ = try? await active?.value
        _ = try? await finishing?.value
    }

    /// Explicitly move a retained capture to a new server, resetting its remote acknowledgement.
    public func configureBackend(_ backendURL: URL) throws {
        guard uploadTask == nil, finishTask == nil else { throw StreamingCaptureError.queueBusy }
        let normalized = try StreamingBackendClient.normalizedURL(backendURL)
        if state.backendURL == normalized.absoluteString { return }
        retryTask?.cancel(); retryTask = nil
        var next = state
        next.backendURL = normalized.absoluteString
        next.uploaded = 0
        next.finished = false
        try save(next)
        lastError = nil
        permanentUploadFailure = false
    }

    @discardableResult
    private func startWorker() -> Task<Void, Error> {
        let id = UUID()
        uploadID = id
        let task = Task { try await self.runWorker(id: id) }
        uploadTask = task
        return task
    }

    private func runWorker(id: UUID) async throws {
        do {
            try await drain()
            retryAttempts = 0
            lastError = nil
            if uploadID == id { uploadTask = nil; uploadID = nil }
        } catch {
            if uploadID == id { uploadTask = nil; uploadID = nil }
            if !(error is CancellationError) {
                lastError = error.localizedDescription
                permanentUploadFailure = Self.isPermanent(error)
                if !uploadsPaused, !state.captureClosed, !permanentUploadFailure { scheduleRetry() }
            }
            throw error
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        let seconds = min(30, 1 << min(retryAttempts, 5))
        retryAttempts += 1
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            await self?.retryAfterDelay()
        }
    }

    private func retryAfterDelay() {
        retryTask = nil
        guard !uploadsPaused, !state.captureClosed, !permanentUploadFailure, uploadTask == nil else { return }
        startWorker()
    }

    private func drain() async throws {
        let backend = try client()
        var acknowledgement = try await backend.begin(manifest)
        try reconcile(acknowledgement)
        var restarts = 0
        while state.uploaded < captured {
            try Task.checkCancellation()
            guard !acknowledgement.finished else {
                throw BackendClientError.invalidResponse("The scan server ended this scan before all frames were sent.")
            }
            let sequence = state.uploaded
            let path = Self.chunkURL(root: root, sequence: sequence)
            let data = try Self.readChunkData(from: path)
            let chunk: StreamChunk
            do { chunk = try JSONDecoder().decode(StreamChunk.self, from: data) }
            catch { throw StreamingCaptureError.missingChunks }
            guard chunk.sequence == sequence else { throw StreamingCaptureError.missingChunks }
            try chunk.validate()
            do {
                acknowledgement = try await backend.uploadEncodedChunk(data, sequence: sequence, manifest: manifest)
                guard acknowledgement.nextSequence == sequence + 1 else {
                    throw BackendClientError.invalidResponse("The scan server acknowledged unexpected frames.")
                }
                try reconcile(acknowledgement)
            } catch let error as BackendClientError where error.isMissingStream && restarts < 1 {
                restarts += 1
                acknowledgement = try await backend.begin(manifest)
                try reconcile(acknowledgement)
            }
        }
    }

    private func finalize() async throws -> StreamSummary {
        defer { finishTask = nil }
        do {
            try await synchronize()
            let backend = try client()
            let summary: StreamSummary
            do { summary = try await backend.finish(manifest, chunkCount: captured) }
            catch let error as BackendClientError where error.isMissingStream {
                try await synchronize()
                summary = try await backend.finish(manifest, chunkCount: captured)
            }
            try reconcile(summary)
            lastError = nil
            return summary
        } catch {
            if !(error is CancellationError) { lastError = error.localizedDescription }
            throw error
        }
    }

    private func reconcile(_ summary: StreamSummary) throws {
        try summary.validate(manifest: manifest)
        guard summary.nextSequence <= captured else { throw StreamingCaptureError.serverAhead }
        guard !summary.finished || summary.nextSequence == captured else {
            throw BackendClientError.invalidResponse("The scan server ended this scan before all frames were sent.")
        }
        var next = state
        next.uploaded = summary.nextSequence
        next.finished = summary.finished
        if summary.finished { next.captureClosed = true }
        try save(next)
    }

    private func client() throws -> StreamingBackendClient {
        guard let address = state.backendURL, let url = URL(string: address) else {
            throw StreamingCaptureError.notConfigured
        }
        return StreamingBackendClient(baseURL: url, session: session)
    }

    private func save(_ checkpoint: Checkpoint) throws {
        try Self.writeJSON(checkpoint, to: root.appendingPathComponent("checkpoint.json"))
        state = checkpoint
    }

    private struct Checkpoint: Codable {
        var backendURL: String?
        var uploaded = 0
        var captureClosed = false
        var finished = false
    }

    private static func chunkURL(root: URL, sequence: Int) -> URL {
        let number = String(sequence)
        let padded = String(repeating: "0", count: max(0, 10 - number.count)) + number
        return root.appendingPathComponent("chunks", isDirectory: true).appendingPathComponent("chunk-\(padded).json")
    }

    private static func savedChunkTotals(at url: URL) throws -> (count: Int, bytes: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                              options: [.skipsSubdirectoryDescendants]) else {
            throw StreamingCaptureError.storageFailure
        }
        var count = 0
        var bytes = 0
        var maximum = -1
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            guard name.hasPrefix("chunk-"), name.hasSuffix(".json") else { continue }
            let number = name.dropFirst(6).dropLast(5)
            let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard let sequence = Int(number), sequence >= 0,
                  chunkURL(root: url.deletingLastPathComponent(), sequence: sequence).lastPathComponent == name,
                  attributes?.isRegularFile == true,
                  let size = attributes?.fileSize, size >= 0, size <= StreamChunk.maximumEncodedBytes else {
                throw StreamingCaptureError.missingChunks
            }
            let total = bytes.addingReportingOverflow(size)
            guard !total.overflow else { throw StreamingCaptureError.captureLimit }
            bytes = total.partialValue
            count += 1
            maximum = max(maximum, sequence)
        }
        guard maximum < Int.max, count == maximum + 1 else { throw StreamingCaptureError.missingChunks }
        return (count, bytes)
    }

    private static func isPermanent(_ error: Error) -> Bool {
        if let backend = error as? BackendClientError {
            switch backend {
            case .http(let status, _, _): return (400...499).contains(status) && status != 408 && status != 429
            case .invalidResponse, .invalidCapture, .invalidURL, .captureConflict: return true
            case .connection: return false
            }
        }
        return error is StreamingCaptureError
    }

    private static func readChunkData(from url: URL) throws -> Data {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= StreamChunk.maximumEncodedBytes else { throw StreamingCaptureError.missingChunks }
        do { return try Data(contentsOf: url) }
        catch { throw StreamingCaptureError.storageFailure }
    }

    private static func readChunk(from url: URL) throws -> StreamChunk {
        let data = try readChunkData(from: url)
        do { return try JSONDecoder().decode(StreamChunk.self, from: data) }
        catch { throw StreamingCaptureError.missingChunks }
    }

    private static func readJSON<T: Decodable>(from url: URL) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) }
        catch { throw StreamingCaptureError.localConflict }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch { throw StreamingCaptureError.storageFailure }
    }
}

private extension BackendClientError {
    var isMissingStream: Bool {
        if case .http(status: 404, code: "stream_not_found", message: _) = self { return true }
        return false
    }
}
