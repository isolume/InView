import Foundation
import Testing
@testable import AccessCore

private func exampleCapture() throws -> CaptureBundle {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { root = root.deletingLastPathComponent() }
    return try JSONDecoder().decode(CaptureBundle.self, from: Data(contentsOf: root.appendingPathComponent("backend/examples/scan.json")))
}

private func exampleScene() throws -> ProcessedScene {
    try JSONDecoder().decode(ProcessedScene.self, from: rustSceneFixture)
}

private func summaryData(_ capture: CaptureBundle) throws -> Data {
    try JSONEncoder().encode(CaptureUploadSummary(id: capture.id, mapID: capture.mapID, floorID: capture.floorID,
                                                 meshCount: capture.meshes.count, frameCount: capture.frames.count,
                                                 objectCount: capture.objects.count, surfaceCount: capture.surfaces.count))
}

private func errorData(_ code: String) -> Data {
    Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"Backend request failed.\"}}".utf8)
}

private struct ExpectedRequest {
    var method: String
    var path: String
    var status: Int
    var data: Data
    var stall: Bool
    var inspect: ((URLRequest) throws -> Void)?
    init(_ method: String, _ path: String, _ status: Int, _ data: Data,
         stall: Bool = false, inspect: ((URLRequest) throws -> Void)? = nil) {
        self.method = method; self.path = path; self.status = status; self.data = data
        self.stall = stall; self.inspect = inspect
    }
}

private final class BackendMockProtocol: URLProtocol {
    static let lock = NSLock()
    static var steps: [ExpectedRequest] = []
    static var failure: String?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        guard !Self.steps.isEmpty else {
            Self.failure = "Unexpected request: \(request.url?.absoluteString ?? "unknown")"
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let expected = Self.steps.removeFirst()
        Self.lock.unlock()
        let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
        guard request.httpMethod == expected.method && path == expected.path else {
            Self.lock.lock()
            Self.failure = "Expected \(expected.method) \(expected.path), received \(request.httpMethod ?? "nil") \(path)"
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do { try expected.inspect?(request) }
        catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if expected.stall { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: expected.status,
                                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: expected.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func mockClient(_ steps: [ExpectedRequest], baseURL: String = "http://backend.invalid") -> (BackendClient, URLSession) {
    BackendMockProtocol.steps = steps
    BackendMockProtocol.failure = nil
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BackendMockProtocol.self]
    let session = URLSession(configuration: config)
    return (BackendClient(baseURL: URL(string: baseURL)!, session: session), session)
}

private func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
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

@Suite(.serialized)
struct BackendIntegrationTests {
    @Test func decodesAndValidatesActualRustResponse() throws {
        let capture = try exampleCapture()
        try capture.validate()
        let scene = try exampleScene()
        try scene.validate(expectedScanID: capture.id, source: capture)
        #expect(scene.objects.map(\.modelKey) == ["chair_v1", "sofa_v1", "table_v1", "bounds_v1"])
        #expect(scene.objects[0].measuredDimensionsM == [0.55, 0.9, 0.6])
        #expect(scene.objects[0].mapFromObject[12...14] == [1.6, 0.45, 0.8])
        #expect(scene.pointCloud.count == 3)
        #expect(scene.surfaces[0].measuredDimensionsM == [6, 0, 5])
        #expect(scene.surfaces[0].renderDimensionsM == [6, 0.025, 5])
    }

    @Test func preservesNativeRoomPlanAndMetadataThroughCodable() throws {
        var capture = try exampleCapture()
        let provider = JSONValue.object([
            "identifier": .string("provider-room"), "version": .number(2),
            "attributes": .array([.null, .bool(true), .object(["size": .number(0.12345)])]),
        ])
        capture.roomplanOriginal = provider
        capture.metadata = .object(["native": provider, "omissions": .array([.string("color")])])
        let data = try JSONEncoder().encode(capture)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["map_id"] as? String == capture.mapID)
        #expect(object["roomplan_original"] != nil)
        let decoded = try JSONDecoder().decode(CaptureBundle.self, from: data)
        #expect(decoded == capture)
        capture.metadata = .null
        capture.roomplanOriginal = .null
        let nullDecoded = try JSONDecoder().decode(CaptureBundle.self, from: JSONEncoder().encode(capture))
        #expect(nullDecoded == capture)
    }

    @Test func rejectsMalformedCaptureGeometryBeforeNetwork() throws {
        var capture = try exampleCapture()
        capture.objects[0].mapFromObject = [1, 0, 0]
        #expect(throws: CaptureValidationError.self) { try capture.validate() }
        capture = try exampleCapture()
        capture.meshes[0].triangles = [[0, 1, 9]]
        #expect(throws: CaptureValidationError.self) { try capture.validate() }
        capture = try exampleCapture()
        capture.frames[0].depth.width = 2
        #expect(throws: CaptureValidationError.self) { try capture.validate() }
        capture = try exampleCapture()
        capture.objects.append(capture.objects[0])
        #expect(throws: CaptureValidationError.self) { try capture.validate() }
    }

    @Test func oversizedCaptureStillBuildsLocallyAndNeverStartsAnUpload() async throws {
        var capture = try exampleCapture()
        capture.roomplanOriginal = .string(String(repeating: "x", count: 32 * 1024 * 1024))
        // An archive's size does not prevent the local map from using its measured geometry.
        let scene = try LocalSceneBuilder.make(from: capture, includeDepthPoints: false)
        #expect(scene.objects.count == capture.objects.count)
        #expect(scene.surfaces.count == capture.surfaces.count)
        let (client, session) = mockClient([])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.upload(capture)
            Issue.record("An oversized upload should be rejected before networking")
        } catch let error as BackendClientError {
            #expect(error == .invalidCapture("This scan is too large to send. You can use its local map instead."))
        }
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func rejectsSceneShapeAndCaptureIdentityMismatch() throws {
        let capture = try exampleCapture()
        var scene = try exampleScene()
        scene.objects[0].obstacleCorners[0] = [1, 2]
        #expect(throws: SceneValidationError.self) { try scene.validate() }
        scene = try exampleScene()
        scene.meshes[0].triangles = [[0, 1, -1]]
        #expect(throws: SceneValidationError.self) { try scene.validate() }
        scene = try exampleScene()
        scene.sourceScanID = "another-scan"
        #expect(throws: SceneValidationError.self) { try scene.validate(source: capture) }
        scene = try exampleScene()
        scene.objects[0].measuredDimensionsM[0] = 10
        #expect(throws: SceneValidationError.self) { try scene.validate(source: capture) }
        scene = try exampleScene()
        scene.coordinates.upAxis = "z"
        #expect(throws: SceneValidationError.self) { try scene.validate() }
    }

    @Test func supportsVersionTwoModelMeshesAndRejectsBadIndices() throws {
        var scene = try exampleScene()
        scene.processingVersion = 2
        scene.objects[0].modelMeshes = [SceneModelMesh(name: "seat", vertices: [[0, 0, 0], [1, 0, 0], [0, 0, 1]],
                                                    normals: [[0, 1, 0], [0, 1, 0], [0, 1, 0]],
                                                    triangles: [[0, 1, 2]], color: "#abcdef")]
        let decoded = try JSONDecoder().decode(ProcessedScene.self, from: JSONEncoder().encode(scene))
        try decoded.validate()
        #expect(decoded.objects[0].modelMeshes.count == 1)
        scene.objects[0].modelMeshes[0].triangles = [[0, 1, 3]]
        #expect(throws: SceneValidationError.self) { try scene.validate() }
        scene = decoded
        scene.processingVersion = 3
        try scene.validate()
        scene.processingVersion = 4
        #expect(throws: SceneValidationError.self) { try scene.validate() }
    }

    @Test func encodesNullDepthConfidenceWithoutChangingItsMeaning() throws {
        let options = SceneProcessingOptions(minimumDepthConfidence: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        #expect(json["minimum_depth_confidence"] is NSNull)
    }

    @Test func uploadsExactCaptureThenFetchesValidatedScene() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/api/scans", 201, try summaryData(capture), inspect: { request in
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                let uploaded = try JSONDecoder().decode(CaptureBundle.self, from: requestBody(request))
                #expect(uploaded == capture)
            }),
            ExpectedRequest("GET", "/api/scans/demo-room/scene", 200, rustSceneFixture),
        ], baseURL: "http://backend.invalid/api/")
        defer { session.invalidateAndCancel() }
        let scene = try await client.uploadAndProcess(capture)
        #expect(scene.sourceScanID == capture.id)
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func olderBackendMissingOutlineRestoresTheImmutableCapturedFloorPolygon() async throws {
        var capture = try exampleCapture()
        let outline: [[Float]] = [
            [-3, 0, -2.5], [3, 0, -2.5], [3, 0, 0], [0, 0, 0], [0, 0, 2.5], [-3, 0, 2.5],
        ]
        capture.surfaces[0].polygonCorners = outline
        for reuseSavedCapture in [false, true] {
            let steps = reuseSavedCapture ? [
                ExpectedRequest("GET", "/scans/demo-room/scene", 200, rustSceneFixture),
                ExpectedRequest("GET", "/scans/demo-room", 200, try JSONEncoder().encode(capture)),
            ] : [
                ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
                ExpectedRequest("GET", "/scans/demo-room/scene", 200, rustSceneFixture),
            ]
            let (client, session) = mockClient(steps)
            defer { session.invalidateAndCancel() }
            let scene: ProcessedScene
            if reuseSavedCapture { scene = try await client.process(capture) }
            else { scene = try await client.uploadAndProcess(capture) }
            #expect(scene.surfaces[0].polygonCorners == outline)
            #expect(scene.surfaces[0].mapFromSurface == capture.surfaces[0].mapFromSurface)
            #expect(scene.surfaces[0].measuredDimensionsM == capture.surfaces[0].dimensionsM)
            #expect(capture.surfaces[0].polygonCorners == outline)
            try scene.validate(source: capture)
            #expect(BackendMockProtocol.steps.isEmpty)
            #expect(BackendMockProtocol.failure == nil)
        }
    }

    @Test func backendSuppliedDifferentOutlineStillFailsSourceVerification() async throws {
        var capture = try exampleCapture()
        capture.surfaces[0].polygonCorners = [[-3, 0, -2.5], [3, 0, -2.5], [3, 0, 2.5], [-3, 0, 2.5]]
        var changed = try exampleScene()
        changed.surfaces[0].polygonCorners = [[-2, 0, -2.5], [2, 0, -2.5], [2, 0, 2.5], [-2, 0, 2.5]]
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, try JSONEncoder().encode(changed)),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.invalidResponse("The scene changed a captured surface's measurements.")) {
            try await client.uploadAndProcess(capture)
        }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func missingOutlineCompatibilityCannotHideChangedSurfacePoseOrDimensions() async throws {
        var capture = try exampleCapture()
        capture.surfaces[0].polygonCorners = [[-3, 0, -2.5], [3, 0, -2.5], [3, 0, 2.5], [-3, 0, 2.5]]
        for changedPose in [false, true] {
            var changed = try exampleScene()
            if changedPose { changed.surfaces[0].mapFromSurface[12] += 1 }
            else { changed.surfaces[0].measuredDimensionsM[0] += 1 }
            let (client, session) = mockClient([
                ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
                ExpectedRequest("GET", "/scans/demo-room/scene", 200, try JSONEncoder().encode(changed)),
            ])
            defer { session.invalidateAndCancel() }
            await #expect(throws: BackendClientError.invalidResponse("The scene changed a captured surface's measurements.")) {
                try await client.uploadAndProcess(capture)
            }
            #expect(BackendMockProtocol.steps.isEmpty)
            #expect(BackendMockProtocol.failure == nil)
        }
    }

    @Test func acceptsDuplicateOnlyAfterVerifyingOriginalCapture() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 409, errorData("scan_exists")),
            ExpectedRequest("GET", "/scans/demo-room", 200, try JSONEncoder().encode(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, rustSceneFixture),
        ])
        defer { session.invalidateAndCancel() }
        _ = try await client.uploadAndProcess(capture)
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func rejectsDuplicateIdentifierWithDifferentSource() async throws {
        let capture = try exampleCapture()
        var different = capture
        different.metadata = .object(["different": .bool(true)])
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 409, errorData("scan_exists")),
            ExpectedRequest("GET", "/scans/demo-room", 200, try JSONEncoder().encode(different)),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.captureConflict) { try await client.uploadAndProcess(capture) }
        #expect(BackendMockProtocol.steps.isEmpty)
    }

    @Test func restoresSavedCaptureAfterBackendRestart() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("GET", "/scans/demo-room/scene", 404, errorData("scan_not_found")),
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, rustSceneFixture),
        ])
        defer { session.invalidateAndCancel() }
        _ = try await client.process(capture)
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func reusesExistingSceneOnlyWithTheMatchingImmutableCapture() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, rustSceneFixture),
            ExpectedRequest("GET", "/scans/demo-room", 200, try JSONEncoder().encode(capture)),
        ])
        defer { session.invalidateAndCancel() }
        let scene = try await client.process(capture)
        #expect(scene.sourceScanID == capture.id)
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func recoversOneRestartBetweenUploadAndSceneFetch() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 404, errorData("scan_not_found")),
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, rustSceneFixture),
        ])
        defer { session.invalidateAndCancel() }
        _ = try await client.uploadAndProcess(capture)
        #expect(BackendMockProtocol.steps.isEmpty)
    }

    @Test func doesNotTreatOtherConflictsOrMissingRoutesAsCaptureRetries() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 409, errorData("other_conflict")),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.http(status: 409, code: "other_conflict", message: "Backend request failed.")) {
            try await client.uploadAndProcess(capture)
        }
        #expect(BackendMockProtocol.steps.isEmpty)
        let (missingClient, missingSession) = mockClient([
            ExpectedRequest("GET", "/scans/demo-room/scene", 404, errorData("route_not_found")),
        ])
        defer { missingSession.invalidateAndCancel() }
        await #expect(throws: BackendClientError.http(status: 404, code: "route_not_found", message: "Backend request failed.")) {
            try await missingClient.process(capture)
        }
        #expect(BackendMockProtocol.steps.isEmpty)
    }

    @Test func rejectsWrongSceneBeforeReturningToRenderer() async throws {
        let capture = try exampleCapture()
        var badScene = try exampleScene()
        badScene.mapID = "different-map"
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, try JSONEncoder().encode(badScene)),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.invalidResponse("The backend returned a different capture.")) {
            try await client.uploadAndProcess(capture)
        }
    }

    @Test func validatesBackendAddressAndEscapesIdentifierSegments() async throws {
        let capture = try exampleCapture()
        let invalidClient = BackendClient(baseURL: URL(string: "file:///private/tmp/backend")!)
        await #expect(throws: BackendClientError.invalidURL) { try await invalidClient.upload(capture) }
        var scene = try exampleScene()
        scene.sourceScanID = "demo/room?"
        let (client, session) = mockClient([
            ExpectedRequest("GET", "/scans/demo%2Froom%3F/scene", 200, try JSONEncoder().encode(scene)),
        ])
        defer { session.invalidateAndCancel() }
        _ = try await client.scene(scanID: "demo/room?")
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func distinguishesUploadAndSceneTimeoutsWithoutChangingScanTimeouts() async throws {
        let capture = try exampleCapture()
        let (uploadClient, uploadSession) = mockClient([
            ExpectedRequest("POST", "/scans", 201, Data(), inspect: { request in
                #expect(request.timeoutInterval == 45)
                throw URLError(.timedOut)
            }),
        ])
        defer { uploadSession.invalidateAndCancel() }
        let uploadError = BackendClientError.connection(stage: .upload, code: .timedOut)
        await #expect(throws: uploadError) { try await uploadClient.uploadAndProcess(capture) }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)

        let (sceneClient, sceneSession) = mockClient([
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 200, Data(), inspect: { request in
                #expect(request.timeoutInterval == 45)
                throw URLError(.timedOut)
            }),
        ])
        defer { sceneSession.invalidateAndCancel() }
        let sceneError = BackendClientError.connection(stage: .scene, code: .timedOut)
        await #expect(throws: sceneError) { try await sceneClient.uploadAndProcess(capture) }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
        #expect(uploadError.localizedDescription != sceneError.localizedDescription)
        #expect(uploadError.localizedDescription.contains("Sending the scan"))
        #expect(sceneError.localizedDescription.contains("3D map"))
    }

    @Test func aNetworkFailureCannotBypassDuplicateCaptureVerification() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 409, errorData("scan_exists")),
            ExpectedRequest("GET", "/scans/demo-room", 200, Data(), inspect: { _ in
                throw URLError(.networkConnectionLost)
            }),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.connection(stage: .original, code: .networkConnectionLost)) {
            try await client.uploadAndProcess(capture)
        }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func preservesNetworkCodesWithoutDisplayingTransportDetails() async throws {
        let codes: [URLError.Code] = [.timedOut, .cannotFindHost, .cannotConnectToHost,
                                     .notConnectedToInternet, .networkConnectionLost,
                                     .appTransportSecurityRequiresSecureConnection,
                                     .secureConnectionFailed, .serverCertificateUntrusted, .unknown]
        for code in codes {
            let (client, session) = mockClient([
                ExpectedRequest("GET", "/health", 200, Data(), inspect: { _ in
                    throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "Private transport detail at http://backend.invalid"])
                }),
            ])
            defer { session.invalidateAndCancel() }
            let expected = BackendClientError.connection(stage: .health, code: code)
            await #expect(throws: expected) { try await client.checkHealth() }
            #expect(!expected.localizedDescription.contains("Private transport detail"))
            #expect(!expected.localizedDescription.contains("backend.invalid"))
            #expect(BackendMockProtocol.steps.isEmpty)
            #expect(BackendMockProtocol.failure == nil)
        }
    }

    @Test func keepsNetworkAndTaskCancellationSilent() async throws {
        let (client, session) = mockClient([
            ExpectedRequest("GET", "/health", 200, Data(), inspect: { _ in throw URLError(.cancelled) }),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: CancellationError.self) { try await client.checkHealth() }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)

        let (started, continuation) = AsyncStream<Void>.makeStream()
        let (pendingClient, pendingSession) = mockClient([
            ExpectedRequest("GET", "/health", 200, Data(), stall: true, inspect: { _ in continuation.yield(()) }),
        ])
        defer { pendingSession.invalidateAndCancel(); continuation.finish() }
        let task = Task { try await pendingClient.checkHealth() }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func healthChecksOnlyTheConfiguredServerWithAShortTimeout() async throws {
        let (client, session) = mockClient([
            ExpectedRequest("GET", "/api/health", 200,
                            Data("{\"status\":\"ok\",\"service\":\"inview-backend\"}".utf8), inspect: { request in
                #expect(request.timeoutInterval == 5)
                #expect(request.httpBody == nil && request.httpBodyStream == nil)
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            }),
        ], baseURL: "http://backend.invalid/api/")
        defer { session.invalidateAndCancel() }
        try await client.checkHealth()
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func oversizedOrUnsupportedArchivesFallBackToPortableJSON() {
        #expect(BackendClientError.http(status: 413, code: "payload_too_large", message: "").isArchiveEndpointUnavailable)
        #expect(BackendClientError.http(status: 404, code: "not_found", message: "").isArchiveEndpointUnavailable)
        #expect(BackendClientError.archiveTooLarge.isArchiveEndpointUnavailable)
        #expect(!BackendClientError.http(status: 422, code: "invalid_request", message: "").isArchiveEndpointUnavailable)
    }

    @Test func sendsBearerTokenToProtectedServer() async throws {
        let (plain, session) = mockClient([
            ExpectedRequest("GET", "/health", 200,
                            Data("{\"status\":\"ok\",\"service\":\"inview-backend\"}".utf8), inspect: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-test-token")
            }),
        ])
        defer { session.invalidateAndCancel() }
        let client = BackendClient(baseURL: URL(string: "https://backend.invalid")!, accessToken: "private-test-token", session: session)
        try await client.checkHealth()
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
        let insecure = BackendClient(baseURL: plain.baseURL, accessToken: "private-test-token", session: session)
        await #expect(throws: BackendClientError.invalidURL) { try await insecure.checkHealth() }
    }

    @Test func healthRejectsAnotherServiceUnavailableStatusAndMalformedResponses() async throws {
        let responses = [
            "{\"status\":\"ok\",\"service\":\"another-app\"}",
            "{\"status\":\"unavailable\",\"service\":\"inview-backend\"}",
            "{\"status\":\"ok\"}",
            "{\"status\":true,\"service\":\"inview-backend\"}",
            "<html>Another application</html>",
        ]
        for response in responses {
            let (client, session) = mockClient([ExpectedRequest("GET", "/health", 200, Data(response.utf8))])
            defer { session.invalidateAndCancel() }
            await #expect(throws: BackendClientError.invalidResponse("This address is not a ready InView scan server.")) {
                try await client.checkHealth()
            }
            #expect(BackendMockProtocol.steps.isEmpty)
            #expect(BackendMockProtocol.failure == nil)
        }
        let (client, session) = mockClient([ExpectedRequest("GET", "/health", 503, errorData("unavailable"))])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.http(status: 503, code: "unavailable", message: "Backend request failed.")) {
            try await client.checkHealth()
        }
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func processingFailuresHaveASpecificMessageAndDoNotRetryTheUpload() async throws {
        let capture = try exampleCapture()
        let (client, session) = mockClient([
            ExpectedRequest("POST", "/scans", 201, try summaryData(capture)),
            ExpectedRequest("GET", "/scans/demo-room/scene", 500, errorData("processing_failed")),
        ])
        defer { session.invalidateAndCancel() }
        let expected = BackendClientError.http(status: 500, code: "processing_failed", message: "Backend request failed.")
        await #expect(throws: expected) { try await client.uploadAndProcess(capture) }
        #expect(expected.localizedDescription.contains("build the 3D map"))
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }
}

extension BackendIntegrationTests {
    @Test func fetchesAnalysisWithAuthorizationAndEscapedID() async throws {
        let (_, session) = mockClient([
            ExpectedRequest("GET", "/api/scans/scan-1/analysis", 200, realisticAnalysisJSON, inspect: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            }),
            ExpectedRequest("GET", "/api/scans/a%2Fb/analysis", 404, errorData("analysis_not_found")),
        ])
        defer { session.invalidateAndCancel() }
        let client = BackendClient(baseURL: URL(string: "https://backend.invalid/api/")!,
                                   accessToken: "secret-token", session: session)
        let analysis = try #require(try await client.analysis(scanID: "scan-1"))
        #expect(analysis.places.count == 7)
        #expect(try await client.analysis(scanID: "a/b") == nil)
        #expect(BackendMockProtocol.steps.isEmpty)
        #expect(BackendMockProtocol.failure == nil)
    }

    @Test func analysisErrorsOtherThanNotYetAnalysedThrow() async throws {
        let (client, session) = mockClient([
            ExpectedRequest("GET", "/scans/missing/analysis", 404, errorData("scan_not_found")),
            ExpectedRequest("GET", "/scans/scan-2/analysis", 200, realisticAnalysisJSON),
            ExpectedRequest("GET", "/scans/scan-3/analysis", 200, Data("[]".utf8)),
        ])
        defer { session.invalidateAndCancel() }
        await #expect(throws: BackendClientError.http(status: 404, code: "scan_not_found", message: "Backend request failed.")) {
            try await client.analysis(scanID: "missing")
        }
        // The response names scan-1, not the requested scan.
        await #expect(throws: BackendClientError.self) { try await client.analysis(scanID: "scan-2") }
        await #expect(throws: BackendClientError.self) { try await client.analysis(scanID: "scan-3") }
        #expect(BackendMockProtocol.steps.isEmpty)
    }

    @Test func analysisRefusesTokenOverPlainHTTPToRemoteHost() async throws {
        let client = BackendClient(baseURL: URL(string: "http://backend.invalid")!, accessToken: "secret-token")
        await #expect(throws: BackendClientError.invalidURL) { try await client.analysis(scanID: "scan-1") }
    }
}
