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
    @Published private(set) var scanNotice: String?
    @Published private(set) var captureView: RoomCaptureView?
    /// Finds the camera placed but didn't see often enough to count. Review asks about each one.
    @Published private(set) var unconfirmed: [AccessibilityDetector.Sighting] = []
    /// The volunteer just walked through a doorway: RoomPlan keeps one room per section, so suggest a new one.
    @Published private(set) var suggestsNewSection = false

    let session = ARSession()
    let detector = AccessibilityDetector()
    private let rawCapture = RawScanCapture()
    private let scanID = UUID()
    private var captureBundle: CaptureBundle?
    private var localScene: ProcessedScene?
    private var sceneTask: Task<Void, Never>?

    var canRetryScene: Bool { captureBundle != nil }
    var canUseLocalScene: Bool { scene == nil && localScene != nil && !isProcessingScene }

    private func makeCaptureView() -> RoomCaptureView {
        rawCapture.prepare(session: session)
        let view = RoomCaptureView(frame: .zero, arSession: session)
        // Camera outlines still show scan coverage; avoid drawing the growing room a second time
        // in a miniature preview hidden behind our controls. Navigation renders it after capture.
        view.isModelEnabled = false
        view.delegate = captureDelegate
        // Live updates too, as Apple's RoomPlan sample does alongside the view's own delegate.
        view.captureSession.delegate = sessionDelegate
        return view
    }

    private let captureDelegate = CaptureViewDelegate()
    private lazy var sessionDelegate = CaptureSessionDelegate(
        onUpdate: { [weak self] room in self?.liveRoomUpdated(room) },
        onEnd: { [weak self] data, error in self?.sectionEnded(data, error: error) }
    )
    private var sectionTask: Task<Void, Never>?
    private var sectionRequestID = UUID()
    private var rooms: [CapturedRoom] = []
    /// Everything RoomPlan reported live in the current section; what its result drops is recovered from here.
    private var memory = RoomMemory()
    private var recovered: [RoomParts] = []
    private var liveDoors: [CapturedRoom.Surface] = []
    /// Which side of each door the camera was on at the last check.
    private var doorSides: [UUID: Float] = [:]
    private var sectionStarted = Date.now
    private var doorMonitor: Timer?
    /// Doorway crossings in the first moments of a section are the volunteer settling in, not leaving.
    private static let doorSuggestionDelay: TimeInterval = 15
    private static let doorMonitorInterval: TimeInterval = 0.5
    private var worldMap: ARWorldMap?
    /// What the camera saw as the scan began, shown later to help riders find their place.
    private var startView: Data?
    private var startViewTimer: Timer?
    private var hasStarted = false
    private var isActive = false
    private var worldMapRequestID = UUID()
    private var sectionStartedAt: TimeInterval = 0
    private var resourceTimer: Timer?
    private var memoryObserver: NSObjectProtocol?
    private var pauseAfterProcessing = false
    private var interruptionAdvice = "Move somewhere with more detail in view, then continue, or finish with what you have."
    private var finishAfterProcessing = false
    private var reportTask: Task<Void, Never>?

    init() {
        phase = RoomCaptureSession.isSupported ? .scanning : .unsupported
    }

    func start() {
        guard phase == .scanning, !hasStarted else { return }
        hasStarted = true
        isActive = true
        let view = makeCaptureView()
        captureView = view
        beginSection()
        beginResourceMonitoring()
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
        guard isActive, phase == .interrupted else { return }
        guard ProcessInfo.processInfo.thermalState != .critical else {
            errorMessage = "Let the phone cool down before continuing. You can finish and save this map now."
            return
        }
        errorMessage = nil
        startSection()
    }

    func dismissSectionSuggestion() {
        suggestsNewSection = false
    }

    /// Captures the session's map of visual features. Also the retry when a capture fails.
    func saveWorldMap() {
        guard isActive else { return }
        // A thermal interruption may have paused tracking. Once cooled, let a retry collect
        // more features without moving the saved sections into a new coordinate space.
        if ProcessInfo.processInfo.thermalState != .critical, let configuration = session.configuration {
            session.run(configuration, options: [])
        }
        phase = .savingWorldMap
        errorMessage = nil
        let requestID = UUID()
        worldMapRequestID = requestID
        session.getCurrentWorldMap { [weak self] worldMap, error in
            Task { @MainActor in
                guard let self, self.isActive, self.worldMapRequestID == requestID else { return }
                self.worldMapCaptured(worldMap, error: error)
            }
        }
    }

    func stop() {
        isActive = false
        worldMapRequestID = UUID()
        sectionRequestID = UUID()
        sectionTask?.cancel()
        sectionTask = nil
        resourceTimer?.invalidate()
        resourceTimer = nil
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        startViewTimer?.invalidate()
        startViewTimer = nil
        doorMonitor?.invalidate()
        doorMonitor = nil
        detector.pause()
        rawCapture.stop()
        sceneTask?.cancel()
        reportTask?.cancel()
        captureView?.delegate = nil
        captureView?.captureSession.delegate = nil
        if phase == .scanning || phase == .processing { captureView?.captureSession.stop() }
        captureView = nil
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
        let report = try await ScanWork.run { try AccessibilityReport.make(map: draft) }
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

    private func endSection(thenFinish finish: Bool, pauseAfter: Bool = false) {
        guard isActive, phase == .scanning else { return }
        finishAfterProcessing = finish
        pauseAfterProcessing = pauseAfter
        phase = .processing
        detector.pause()
        doorMonitor?.invalidate()
        doorMonitor = nil
        suggestsNewSection = false
        rawCapture.pause()
        // Keep the AR session running so the next section and the world map share its coordinates.
        captureView?.captureSession.stop(pauseARSession: false)
    }

    /// Runs a RoomPlan capture for a new section and resets what's remembered about the live room.
    private func beginSection() {
        guard isActive, let captureView else { return }
        memory = RoomMemory()
        liveDoors = []
        doorSides = [:]
        sectionStarted = .now
        sectionStartedAt = ProcessInfo.processInfo.systemUptime
        suggestsNewSection = false
        doorMonitor?.invalidate()
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        doorMonitor = Timer.scheduledTimer(withTimeInterval: Self.doorMonitorInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDoorways() }
        }
    }

    private func liveRoomUpdated(_ room: CapturedRoom) {
        guard isActive, phase == .scanning else { return }
        memory.remember(room)
        liveDoors = room.doors
    }

    /// Remembers what RoomPlan saw live that its processed room left out, so the map keeps it.
    private func recoverDroppedParts(from room: CapturedRoom) {
        let missing = memory.missing(from: room)
        Log.scan.notice("section \(self.rooms.count): RoomPlan kept \(RoomParts(room).count) of \(self.memory.count) live items; recovering \(missing.count)")
        if !missing.isEmpty { recovered.append(missing) }
    }

    /// Notices the camera passing through a doorway RoomPlan has found, and suggests a new section once.
    private func checkDoorways() {
        guard isActive, phase == .scanning, !suggestsNewSection, let frame = session.currentFrame else { return }
        let camera = frame.camera.transform.translation
        let position = SIMD2(camera.x, camera.z)
        var sides: [UUID: Float] = [:]
        var crossed = false
        for door in liveDoors {
            let center = SIMD2(door.transform.columns.3.x, door.transform.columns.3.z)
            let along = SIMD2(door.transform.columns.0.x, door.transform.columns.0.z)
            let normal = SIMD2(door.transform.columns.2.x, door.transform.columns.2.z)
            guard simd_length(along) > 1e-3, simd_length(normal) > 1e-3 else { continue }
            let offset = position - center
            let lateral = simd_dot(offset, simd_normalize(along))
            let depth = simd_dot(offset, simd_normalize(normal))
            guard abs(lateral) <= door.dimensions.x / 2 + 0.4, abs(depth) < 1.2 else { continue }
            sides[door.identifier] = depth
            if let previous = doorSides[door.identifier], previous.sign != depth.sign, abs(previous) > 0.05, abs(depth) > 0.05 {
                crossed = true
            }
        }
        doorSides = sides
        if crossed, Date.now.timeIntervalSince(sectionStarted) > Self.doorSuggestionDelay {
            Log.scan.notice("camera crossed a doorway; suggesting a new section")
            suggestsNewSection = true
        }
    }

    private func sectionProcessed(_ room: CapturedRoom) {
        guard isActive else { return }
        switch phase {
        case .processing:
            rooms.append(room)
            sectionCount = rooms.count
            Log.scan.notice("section \(self.rooms.count) processed: \(room.walls.count) walls, \(room.doors.count) doors, \(room.objects.count) objects")
            recoverDroppedParts(from: room)
            if finishAfterProcessing {
                saveWorldMap()
            } else if pauseAfterProcessing {
                phase = .interrupted
                if ProcessInfo.processInfo.thermalState == .critical { session.pause() }
            } else {
                startSection()
            }
        default:
            Log.scan.notice("ignored a processed room while \(String(describing: self.phase), privacy: .public)")
        }
    }

    /// The session delegate supplies each section once, alongside its live updates. Skip
    /// RoomCaptureView's additional model rendering and process the immutable section here.
    private func sectionEnded(_ data: CapturedRoomData, error: Error?) {
        guard isActive, phase == .scanning || phase == .processing, sectionTask == nil else { return }
        doorMonitor?.invalidate()
        doorMonitor = nil
        suggestsNewSection = false
        let endedUnexpectedly = phase == .scanning
        if endedUnexpectedly {
            Log.scan.error("RoomPlan ended the active section: \(error?.localizedDescription ?? "no error reported", privacy: .public)")
            finishAfterProcessing = false
            pauseAfterProcessing = true
            phase = .processing
            detector.pause()
            rawCapture.pause()
            if ProcessInfo.processInfo.thermalState == .critical {
                session.pause()
            } else if let configuration = session.configuration {
                session.run(configuration, options: [])
            }
        }
        if let error {
            captureFailed(error)
            pauseAfterProcessing = true
        }
        let requestID = UUID()
        sectionRequestID = requestID
        sectionTask = Task { [weak self] in
            do {
                let builder = RoomBuilder(options: [.beautifyObjects])
                let room = try await builder.capturedRoom(from: data)
                try Task.checkCancellation()
                guard let self, self.isActive, self.sectionRequestID == requestID else { return }
                self.sectionTask = nil
                self.sectionProcessed(room)
            } catch {
                guard !Task.isCancelled, let self, self.isActive, self.sectionRequestID == requestID else { return }
                self.sectionTask = nil
                self.errorMessage = "Couldn't finish this section. \(error.localizedDescription)"
                self.interruptionAdvice = "Try a smaller section, or finish with the completed sections."
                self.phase = .interrupted
            }
        }
    }

    private func startSection() {
        guard isActive, captureView != nil else { return }
        pauseAfterProcessing = false
        scanNotice = nil
        errorMessage = nil
        phase = .scanning
        beginSection()
        detector.resume()
        rawCapture.resume()
    }

    private func worldMapCaptured(_ worldMap: ARWorldMap?, error: Error?) {
        guard isActive, phase == .savingWorldMap else { return }
        guard let worldMap else {
            errorMessage = ProcessInfo.processInfo.thermalState == .critical
                ? "The phone needs to cool down before it can save the map. Let it rest, then try again."
                : "Couldn't capture the AR map (\(error?.localizedDescription ?? "unknown error")). Move the phone slowly around the area and try again."
            return
        }
        self.worldMap = worldMap
        startViewTimer?.invalidate()
        startViewTimer = nil
        session.pause()
        captureView?.delegate = nil
        captureView?.captureSession.delegate = nil
        captureView = nil
        resourceTimer?.invalidate()
        resourceTimer = nil
        unconfirmed = detector.unconfirmedSightings()
        prepareScene()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// RoomPlan's values are copied into one immutable payload before export leaves the main thread.
    private struct ExportPayload: @unchecked Sendable {
        let rooms: [CapturedRoom]
        let recovered: [RoomParts]
        let raw: RawScanSnapshot
        let scanID: UUID
    }

    private func prepareScene() {
        let rooms = rooms
        let recovered = recovered
        let points = detector.accessPoints()
        let stairs = detector.stairsFootprints()
        let scanID = scanID
        sceneError = nil
        phase = .processingScene
        isProcessingScene = true
        sceneTask = Task { [weak self] in
            defer { self?.isProcessingScene = false }
            do {
                guard let self else { return }
                let raw = await self.rawCapture.finishSnapshot()
                try Task.checkCancellation()
                self.draft = try await ScanWork.run {
                    MapBuilder.build(rooms: rooms, recovered: recovered, points: points, spottedStairs: stairs)
                }
                let payload = ExportPayload(rooms: rooms, recovered: recovered, raw: raw, scanID: scanID)
                let prepared = try await ScanWork.run {
                    let rawData = try ScanExporter.rawSnapshotData(payload.raw)
                    try Task.checkCancellation()
                    let roomData = try ScanExporter.nativeRoomPlanData(rooms: payload.rooms)
                    // Originals survive even if their portable export is too large or unsupported.
                    try CaptureStore.stageOriginals(id: payload.scanID.uuidString, rawData: rawData, roomPlanData: roomData)
                    let bundle = try ScanExporter.bundle(rooms: payload.rooms, recovered: payload.recovered, raw: payload.raw,
                                                         scanID: payload.scanID, mapID: payload.scanID)
                    try CaptureStore.stageBundle(bundle)
                    // Depth remains archived for reprocessing; the navigation overview uses
                    // measured walls and objects and does not need a second point cloud.
                    return (bundle, try LocalSceneBuilder.make(from: bundle, includeDepthPoints: false))
                }
                try Task.checkCancellation()
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
            result = try await ScanWork.run { try LocalSceneBuilder.make(from: bundle, includeDepthPoints: false) }
        }
        try Task.checkCancellation()
        try await ScanWork.run(priority: .utility) { try CaptureStore.saveScene(result, for: bundle) }
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
            do {
                let report = try await ScanWork.run(priority: .utility) { try AccessibilityReport.make(map: draft) }
                guard !Task.isCancelled else { return }
                self?.report = report
            } catch { /* A superseded draft must not publish a partial report. */ }
        }
    }

    var canFinishInterruptedScan: Bool { !rooms.isEmpty }

    var interruptionHint: String {
        sectionCount == 0 ? "No completed sections yet. Continue scanning a smaller area."
            : "\(sectionCount == 1 ? "1 section is" : "\(sectionCount) sections are") kept. \(interruptionAdvice)"
    }

    private func captureFailed(_ error: Error) {
        guard isActive else { return }
        errorMessage = error.localizedDescription
        switch error as? RoomCaptureSession.CaptureError {
        case .deviceTooHot:
            errorMessage = "The phone needs to cool down. You can finish and save what you've scanned."
            interruptionAdvice = "Let the phone cool down before continuing, or finish and save now."
        case .exceedSceneSizeLimit:
            errorMessage = "This section has reached the scanner's size limit."
            interruptionAdvice = "Continue with a smaller section of this area, or finish and save now."
        default:
            interruptionAdvice = "Move somewhere with more detail in view, then continue, or finish with what you have."
        }
    }

    private func beginResourceMonitoring() {
        resourceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkResources() }
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pauseForResources(message: "The phone is running low on memory.") }
        }
    }

    private func checkResources() {
        guard isActive, phase == .scanning else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            pauseForResources(message: "The phone needs to cool down.")
        case .serious:
            scanNotice = "The phone is warming up. Finish this section and take a short break."
        default:
            scanNotice = ProcessInfo.processInfo.systemUptime - sectionStartedAt >= 180
                ? "For a large area, start the next section to keep scanning smoothly." : nil
        }
    }

    private func pauseForResources(message: String) {
        guard isActive, phase == .scanning else { return }
        errorMessage = message
        interruptionAdvice = "Take a short break before continuing, or finish and save now."
        endSection(thenFinish: false, pauseAfter: true)
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

/// Forwards RoomPlan's live session updates to closures on the main actor.
final class CaptureSessionDelegate: NSObject, RoomCaptureSessionDelegate {
    private let onUpdate: @MainActor (CapturedRoom) -> Void
    private let onEnd: @MainActor (CapturedRoomData, Error?) -> Void

    init(onUpdate: @escaping @MainActor (CapturedRoom) -> Void, onEnd: @escaping @MainActor (CapturedRoomData, Error?) -> Void) {
        self.onUpdate = onUpdate
        self.onEnd = onEnd
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor in onUpdate(room) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in onEnd(data, error) }
    }
}

/// RoomCaptureView requires an NSCoding delegate. Its preview processing is disabled because
/// the session delegate already supplies the data to our cancellable RoomBuilder task.
final class CaptureViewDelegate: NSObject, RoomCaptureViewDelegate {
    override init() { super.init() }
    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {}

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        return false
    }
}
