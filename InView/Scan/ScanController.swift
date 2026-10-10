import ARKit
import AccessCore
import Combine
import RoomPlan
import SwiftUI

/// Drives a volunteer scan: RoomPlan capture of one or more sections with live vision detection,
/// then an ARWorldMap snapshot that navigation sessions relocalize against, so they share the scan's coordinates.
@MainActor
final class ScanController: ObservableObject {
    enum Phase: Equatable {
        case unsupported
        case scanning
        case processing
        /// RoomPlan ended the section on its own, usually after tracking failed. The room is kept, and the
        /// volunteer chooses whether to scan more or finish.
        case interrupted
        case savingWorldMap
        case processingScene
        case review
    }

    @Published private(set) var phase: Phase
    @Published private(set) var sectionCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var draft: VenueMap? {
        didSet { scheduleReport() }
    }
    @Published private(set) var report: AccessibilityReport?
    @Published private(set) var scene: ProcessedScene?
    @Published private(set) var sceneError: String?
    @Published private(set) var isProcessingScene = false
    /// Finds the camera placed but didn't see often enough to count. Review asks about each one.
    @Published private(set) var unconfirmed: [AccessibilityDetector.Sighting] = []

    let session = ARSession()
    let detector = AccessibilityDetector()
    private let rawCapture = RawScanCapture()
    private let scanID = UUID()
    private var captureBundle: CaptureBundle?
    private var localScene: ProcessedScene?
    private var sceneTask: Task<Void, Never>?

    var canRetryScene: Bool { captureBundle != nil }
    var canUseLocalScene: Bool { scene == nil && localScene != nil && !isProcessingScene }

    private(set) lazy var captureView: RoomCaptureView = {
        rawCapture.prepare(session: session)
        let view = RoomCaptureView(frame: .zero, arSession: session)
        view.delegate = captureDelegate
        return view
    }()

    private lazy var captureDelegate = CaptureViewDelegate(
        onError: { [weak self] error in self?.errorMessage = error.localizedDescription },
        onRoom: { [weak self] room in self?.sectionProcessed(room) }
    )
    private var rooms: [CapturedRoom] = []
    private var worldMap: ARWorldMap?
    /// What the camera saw as the scan began, shown later to help riders find their place.
    private var startView: Data?
    private var startViewTimer: Timer?
    private var hasStarted = false
    private var finishAfterProcessing = false
    private var reportTask: Task<Void, Never>?

    init() {
        phase = RoomCaptureSession.isSupported ? .scanning : .unsupported
    }

    func start() {
        guard phase == .scanning, !hasStarted else { return }
        hasStarted = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        rawCapture.start(session: session)
        detector.start(session: session)
        startViewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureStartView() }
        }
    }

    /// Ends the current section and starts another in the same coordinate space, for floors too big for one scan.
    func addSection() { endSection(thenFinish: false) }

    func finish() {
        // After an interruption there's no section to stop; RoomPlan already processed it.
        if phase == .interrupted {
            saveWorldMap()
        } else {
            endSection(thenFinish: true)
        }
    }

    /// Starts another section after RoomPlan ended one by itself.
    func continueScanning() {
        guard phase == .interrupted else { return }
        errorMessage = nil
        startSection()
    }

    /// Captures the session's map of visual features. Also the retry when a capture fails.
    func saveWorldMap() {
        phase = .savingWorldMap
        errorMessage = nil
        session.getCurrentWorldMap { [weak self] worldMap, error in
            Task { @MainActor in self?.worldMapCaptured(worldMap, error: error) }
        }
    }

    func stop() {
        startViewTimer?.invalidate()
        startViewTimer = nil
        detector.pause()
        rawCapture.stop()
        sceneTask?.cancel()
        reportTask?.cancel()
        if phase == .scanning { captureView.captureSession.stop() }
        if phase != .unsupported { session.pause() }
    }

    func addPoint(_ kind: AccessPoint.Kind, at floorPoint: SIMD2<Float>, name: String? = nil) {
        guard let floorY = draft?.floorY else { return }
        let position = SIMD3(floorPoint.x, floorY, floorPoint.y)
        guard var map = draft else { return }
        MapBuilder.add(AccessPoint(kind: kind, name: name, position: position, source: .manual, confidence: 1), to: &map)
        draft = map
    }

    func removePoints(at offsets: IndexSet) {
        draft?.points.remove(atOffsets: offsets)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = draft?.points.firstIndex(where: { $0.id == id }) else { return }
        draft?.points[index].name = name
    }

    func setGeographicReference(_ reference: BuildingMapReference) throws {
        try reference.validate()
        draft?.geographicReference = reference
    }

    var placementPosition: SIMD2<Float>? {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1 else { return nil }
        return SIMD2(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.z)
    }

    func removeStairs(_ stairs: Footprint) {
        draft?.footprints.removeAll { $0 == stairs }
    }

    func setRequiresAssistance(_ id: UUID, _ value: Bool) {
        guard let index = draft?.points.firstIndex(where: { $0.id == id }) else { return }
        draft?.points[index].requiresAssistance = value
    }

    /// The volunteer vouches for an unconfirmed find: it goes on the map like a confirmed one.
    func keep(_ sighting: AccessibilityDetector.Sighting) {
        guard var map = draft else { return }
        if let point = AccessibilityDetector.accessPoint(for: sighting) {
            MapBuilder.add(point, to: &map)
        } else if let stairs = AccessibilityDetector.stairsFootprint(for: sighting) {
            MapBuilder.add(spottedStairs: stairs, to: &map)
        }
        draft = map
        unconfirmed.removeAll { $0.id == sighting.id }
    }

    func drop(_ sighting: AccessibilityDetector.Sighting) {
        unconfirmed.removeAll { $0.id == sighting.id }
    }

    /// Writes the map; the world map archive runs off the main thread.
    func save() async throws {
        guard let draft, let worldMap else { return }
        // Build against the exact saved draft, even if its debounced review report is still pending.
        let report = await Task.detached(priority: .userInitiated) { AccessibilityReport(map: draft) }.value
        try await MapStore.save(draft, report: report, rooms: rooms, worldMap: worldMap, startView: startView)
        if let captureBundle { try CaptureStore.select(captureBundle) }
        else { CaptureStore.clearSelection() }
    }

    func retryScene() {
        guard !isProcessingScene, let captureBundle else { return }
        processScene(captureBundle, backendURL: AppConfig.backendURL)
    }

    func useLocalScene() {
        guard canUseLocalScene, let captureBundle else { return }
        processScene(captureBundle, backendURL: nil)
    }

    private func endSection(thenFinish finish: Bool) {
        guard phase == .scanning else { return }
        finishAfterProcessing = finish
        phase = .processing
        detector.pause()
        rawCapture.pause()
        // Keep the AR session running so the next section and the world map share its coordinates.
        captureView.captureSession.stop(pauseARSession: false)
    }

    private func sectionProcessed(_ room: CapturedRoom) {
        switch phase {
        case .processing:
            rooms.append(room)
            sectionCount = rooms.count
            Log.scan.notice("section \(self.rooms.count) processed: \(room.walls.count) walls, \(room.doors.count) doors, \(room.objects.count) objects")
            if finishAfterProcessing {
                saveWorldMap()
            } else {
                startSection()
            }
        case .scanning:
            // RoomPlan stopped the section itself (for example "too many bad tracking reports"). Keep what it
            // scanned rather than losing the room and leaving the volunteer looking at a frozen session.
            rooms.append(room)
            sectionCount = rooms.count
            detector.pause()
            rawCapture.pause()
            Log.scan.error("RoomPlan ended section \(self.rooms.count) on its own: \(self.errorMessage ?? "no error reported", privacy: .public)")
            // RoomPlan may have paused the shared AR session; keep tracking alive so the world map can still
            // be captured and the next section starts in the same coordinates.
            if let configuration = session.configuration {
                session.run(configuration)
            }
            phase = .interrupted
        default:
            Log.scan.notice("ignored a processed room while \(String(describing: self.phase), privacy: .public)")
        }
    }

    private func startSection() {
        phase = .scanning
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        detector.resume()
        rawCapture.resume()
    }

    private func worldMapCaptured(_ worldMap: ARWorldMap?, error: Error?) {
        guard phase == .savingWorldMap else { return }
        guard let worldMap else {
            errorMessage = "Couldn't capture the AR map (\(error?.localizedDescription ?? "unknown error")). Move the phone slowly around the area and try again."
            return
        }
        self.worldMap = worldMap
        rawCapture.stop()
        session.pause()
        draft = MapBuilder.build(rooms: rooms, points: detector.accessPoints(), spottedStairs: detector.stairsFootprints())
        unconfirmed = detector.unconfirmedSightings()
        prepareScene(raw: rawCapture.snapshot())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// RoomPlan's values are copied into one immutable payload before export leaves the main thread.
    private struct ExportPayload: @unchecked Sendable {
        let rooms: [CapturedRoom]
        let raw: RawScanSnapshot
        let scanID: UUID
    }

    private func prepareScene(raw: RawScanSnapshot) {
        let payload = ExportPayload(rooms: rooms, raw: raw, scanID: scanID)
        sceneError = nil
        phase = .processingScene
        isProcessingScene = true
        sceneTask = Task { [weak self] in
            defer { self?.isProcessingScene = false }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let rawData = try ScanExporter.rawSnapshotData(payload.raw)
                    let roomData = try ScanExporter.nativeRoomPlanData(rooms: payload.rooms)
                    // Originals survive even if their portable export is too large or unsupported.
                    try CaptureStore.stageOriginals(id: payload.scanID.uuidString, rawData: rawData, roomPlanData: roomData)
                    let bundle = try ScanExporter.bundle(rooms: payload.rooms, raw: payload.raw,
                                                         scanID: payload.scanID, mapID: payload.scanID)
                    try CaptureStore.stage(bundle, rawData: rawData, roomPlanData: roomData)
                    return (bundle, try LocalSceneBuilder.make(from: bundle))
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                self.captureBundle = prepared.0
                self.localScene = prepared.1
                self.scene = try await self.makeScene(prepared.0, backendURL: AppConfig.backendURL)
            } catch {
                if !Task.isCancelled { self?.sceneError = error.localizedDescription }
            }
            if !Task.isCancelled { self?.phase = .review }
        }
    }

    private func processScene(_ bundle: CaptureBundle, backendURL: URL?) {
        sceneError = nil
        isProcessingScene = true
        sceneTask = Task { [weak self] in
            defer { self?.isProcessingScene = false }
            do {
                guard let self else { return }
                self.scene = try await self.makeScene(bundle, backendURL: backendURL)
            } catch {
                if !Task.isCancelled { self?.sceneError = error.localizedDescription }
            }
            if !Task.isCancelled { self?.phase = .review }
        }
    }

    private func makeScene(_ bundle: CaptureBundle, backendURL: URL?) async throws -> ProcessedScene {
        let result: ProcessedScene
        if let backendURL {
            result = try await BackendClient(baseURL: backendURL).uploadAndProcess(bundle)
        } else if let localScene {
            result = localScene
        } else {
            result = try await Task.detached(priority: .userInitiated) { try LocalSceneBuilder.make(from: bundle) }.value
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) { try CaptureStore.saveScene(result, for: bundle) }.value
        try Task.checkCancellation()
        return result
    }

    /// Recomputes the report a moment after the draft stops changing; it runs route searches, so keep it off the main thread.
    private func scheduleReport() {
        reportTask?.cancel()
        guard let draft else {
            report = nil
            return
        }
        reportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let report = await Task.detached(priority: .userInitiated) { AccessibilityReport(map: draft) }.value
            guard !Task.isCancelled else { return }
            self?.report = report
        }
    }

    private func captureStartView() {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              let snapshot = FrameEncoder.snapshot(frame.capturedImage) else { return }
        startViewTimer?.invalidate()
        startViewTimer = nil
        Task { [weak self] in
            let jpeg = await Task.detached(priority: .utility) { FrameEncoder.portraitJPEG(from: snapshot, maxDimension: 720) }.value
            self?.startView = jpeg
        }
    }
}

/// RoomCaptureView requires an NSCoding delegate; this adapter forwards its results to closures.
final class CaptureViewDelegate: NSObject, RoomCaptureViewDelegate {
    private let onError: @MainActor (Error) -> Void
    private let onRoom: @MainActor (CapturedRoom) -> Void

    init(onError: @escaping @MainActor (Error) -> Void, onRoom: @escaping @MainActor (CapturedRoom) -> Void) {
        self.onError = onError
        self.onRoom = onRoom
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { Task { @MainActor in onError(error) } }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            if let error { onError(error) }
            onRoom(processedResult)
        }
    }
}
