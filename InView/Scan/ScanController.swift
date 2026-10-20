import ARKit
import AccessCore
import Combine
import RoomPlan
import SwiftUI
import UIKit

/// Drives a volunteer scan: RoomPlan capture of rooms with live vision detection,
/// then an ARWorldMap snapshot that navigation sessions relocalize against, so they share the scan's coordinates.
@MainActor
final class ScanController: ObservableObject {
    enum SceneStage: Equatable {
        case preparing, reconstructing, saving
    }
    enum Phase: Equatable {
        case unsupported
        case choosingFloor
        case scanning
        case processing
        /// RoomPlan ended the section on its own, usually after tracking failed. The room is kept, and the
        /// volunteer chooses whether to scan more or finish.
        case interrupted
        case savingWorldMap
        case processingScene
        case switchingFloor
        case review
    }

    @Published private(set) var phase: Phase {
        didSet { updateIdleTimer() }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var draft: VenueMap? {
        didSet {
            scheduleReport()
            // A reviewed edit changes the immutable evidence sent by the next request.
            pendingAnalysis = nil
            draftRevision &+= 1
        }
    }
    @Published private(set) var report: AccessibilityReport?
    @Published private(set) var scene: ProcessedScene?
    @Published private(set) var detailScene: ProcessedScene?
    @Published private(set) var detailError: String?
    @Published private(set) var isPreparingDetail = false
    @Published private(set) var analysisCandidates: [ScanAnalysis.Place] = []
    @Published private(set) var analysisHighlights: ScanHighlights?
    @Published private(set) var analysisStatus: String?
    @Published private(set) var analysisError: String?
    @Published private(set) var isFindingPlaces = false
    @Published private(set) var sceneError: String?
    @Published private(set) var isProcessingScene = false
    @Published private(set) var sceneStage: SceneStage = .preparing
    @Published private(set) var scanNotice: String?
    @Published private(set) var trackingNotice: String?
    @Published private(set) var scanGuidance = "Move slowly and include the floor as you scan."
    @Published private(set) var walkTrace: ScanWalkTrace?
    @Published private(set) var walkCoverage: ScanWalkFloorCoverage.Assessment?
    @Published private(set) var originalScanWarning: String?
    @Published private(set) var videoStatus: String?
    @Published private(set) var videoDepthNotice: String?
    @Published private(set) var captureView: ScanPreviewCameraView?
    /// Finds the camera placed but didn't see often enough to count. Review asks about each one.
    @Published private(set) var unconfirmed: [AccessibilityDetector.Sighting] = []
    @Published private(set) var signObservations: [CaptureTextObservation] = []
    /// Signs the mapper pointed the reader at; they label their doors when the map is ready.
    @Published private(set) var readSigns: [SignReader.Sighting] = []
    /// Every place sign OCR read in passing, kept for the whole scan. The capture's own list drops
    /// observations as it trims old frames, which used to lose signs read early on.
    private var passiveSigns: [(reading: SignReading, text: String, position: SIMD3<Float>, viewer: SIMD3<Float>?, count: Int)] = []
    private var countedObservations: Set<String> = []
    @Published private(set) var currentFloor: ScanFloorIdentity?
    @Published private(set) var buildingName = "Building"
    @Published private(set) var isChangingFloors = false
    @Published private(set) var proposedFloorLevel: Int?
    @Published private(set) var automaticFloorDetectionUnavailable = false

    private(set) var session = ARSession()
    private(set) var detector = AccessibilityDetector()
    private var rawCapture = RawScanCapture()
    private var videoCapture: ScanVideoCapture?
    private lazy var splatCapture = SplatCapture(scanID: scanID)
    private var scanID = UUID()
    private let elevationMonitor = FloorElevationMonitor()
    private var pendingFloor: ScanFloorIdentity?
    private var floorChangePausedCapture = false
    private var floorSwitchTask: Task<Void, Never>?
    private var captureBundle: CaptureBundle?
    private var localScene: ProcessedScene?
    private var finishedRawSnapshot: RawScanSnapshot?
    private var rawArchived = false
    private var sceneTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var detailRequested = false
    private var reviewedAnalysisIDs: Set<String> = []
    private var pendingAnalysis: (scanID: String, server: URL)?
    private var draftRevision = 0
    var sceneStatusLine: String {
        switch sceneStage {
        case .preparing: return "Preparing rooms…"
        case .reconstructing: return "Building map…"
        case .saving: return "Saving map…"
        }
    }
    /// Saving the room the mapper just walked out of; the scan carries on once it's done.
    var isSavingRoomLeft: Bool { phase == .processing && !pauseAfterProcessing && !finishAfterProcessing }
    var canRetryScene: Bool { !rooms.isEmpty || captureBundle != nil }
    var canUseLocalScene: Bool { localScene != nil && scene == nil && !isProcessingScene }
    var canPlaceReviewPoints: Bool {
        scene != nil && !isProcessingScene
    }

    private var captureSession: RoomCaptureSession?

    private func makeCaptureView() -> ScanPreviewCameraView {
        rawCapture.prepare(session: session)
        // Capture the complete room without RoomCaptureView's growing visualization.
        // The camera renderer loads only nearby measured edges, with a fixed display budget.
        let capture = RoomCaptureSession(arSession: session)
        let id = scanID
        sessionDelegate = CaptureSessionDelegate(
            onStart: { [weak self] in
                guard let self, self.scanID == id, self.isActive, self.phase == .scanning else { return }
                self.rawCapture.restoreDepthAfterRoomPlanStart(session: self.session)
            },
            onEnd: { [weak self] data, error in
                guard self?.scanID == id else { return }
                self?.sectionEnded(data, error: error)
            },
            onInstruction: { [weak self] instruction in
                guard self?.scanID == id else { return }
                self?.updateInstruction(instruction)
            }
        )
        capture.delegate = sessionDelegate
        captureSession = capture
        let view = ScanPreviewCameraView(session: session)
        view.onMeasurementsReady = { [weak self] measurements in
            guard self?.scanID == id else { return }
            self?.applyLiveRoomMeasurements(measurements)
        }
        return view
    }

    private var sessionDelegate: CaptureSessionDelegate?
    private var sectionTask: Task<Void, Never>?
    private var sectionRequestID = UUID()
    private var pendingRoomData: CapturedRoomData?
    private var pendingRoomSourceID: UUID?
    private var rooms: [CapturedRoom] = []
    private var liveFloors: [Footprint] = []
    private var livePortals: [RoomTransitionPortal] = []
    /// Walking out through a door ends the room there, so the next space starts with a fresh
    /// RoomPlan model instead of growing the last one.
    private var roomTransitions = RoomTransitionDetector()
    private var roomInstruction: String?
    private var roomInstructionTime: TimeInterval = 0
    private var previewMonitor: Timer?
    private static let previewMonitorInterval: TimeInterval = 0.2
    private var worldMap: ARWorldMap?
    /// What the camera saw as the scan began, shown later to help riders find their place.
    private var startView: Data?
    private var startViewTimer: Timer?
    private var hasStarted = false
    private var isActive = false {
        didSet { updateIdleTimer() }
    }
    private var appIsActive = UIApplication.shared.applicationState == .active
    private var previousIdleTimerDisabled: Bool?
    private var worldMapRequestID = UUID()
    private var resourceTimer: Timer?
    private var memoryObserver: NSObjectProtocol?
    private var pauseAfterProcessing = false
    private var interruptionAdvice = "Move somewhere with more detail in view, then continue, or finish with what you have."
    private var finishAfterProcessing = false
    private var reportTask: Task<Void, Never>?

    init() {
        phase = RoomCaptureSession.isSupported ? .choosingFloor : .unsupported
        elevationMonitor.onMovement = { [weak self] in self?.pauseForFloorChange() }
        elevationMonitor.onLanding = { [weak self] proposal in
            guard let self, let currentFloor = self.currentFloor,
                  self.isActive, self.isChangingFloors, self.pendingFloor == nil,
                  self.phase == .scanning || self.phase == .processing || self.phase == .interrupted else { return }
            let sum = currentFloor.level.addingReportingOverflow(proposal.floorDelta)
            guard !sum.overflow else { return }
            self.proposedFloorLevel = min(300, max(-20, sum.partialValue))
        }
        elevationMonitor.onUnavailable = { [weak self] in self?.automaticFloorDetectionUnavailable = true }
    }

    #if DEBUG
    /// Exercise finishing with immutable recorded inputs, without starting camera hardware.
    convenience init(completedRooms: [CapturedRoom], rawSnapshot: RawScanSnapshot, scanID: UUID,
                     originalWarning: String? = nil) {
        self.init()
        self.rooms = completedRooms
        self.finishedRawSnapshot = rawSnapshot
        self.scanID = scanID
        self.originalScanWarning = originalWarning
        self.isActive = true
        prepareScene()
    }

    func waitForScenePreparation() async { await sceneTask?.value }
    #endif

    func setAppIsActive(_ active: Bool) {
        appIsActive = active
        updateIdleTimer()
        if !active { videoCapture?.pause() }
        else if phase == .scanning || (phase == .processing && !pauseAfterProcessing && !finishAfterProcessing) {
            videoCapture?.resume()
        }
    }

    private func updateIdleTimer() {
        let needsAwakeScreen: Bool
        switch phase {
        case .scanning, .processing, .savingWorldMap:
            // Room handoffs and the final tracking snapshot still belong to the live capture.
            needsAwakeScreen = isActive && appIsActive
        default:
            needsAwakeScreen = false
        }
        if needsAwakeScreen {
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }

    func startScanning(on floor: ScanFloorIdentity, buildingName: String) {
        guard phase == .choosingFloor else { return }
        currentFloor = floor
        self.buildingName = buildingName
        phase = .scanning
        start()
    }

    func start() {
        guard phase == .scanning, !hasStarted else { return }
        hasStarted = true
        isActive = true
        detailRequested = AppConfig.detailedScanning
        rawCapture = RawScanCapture(reconstructsMesh: detailRequested)
        rawCapture.floorID = currentFloor?.id.uuidString ?? "ground"
        detector.floorElevation = { [weak self] position in
            guard let self else { return nil }
            if let floor = self.liveFloors.first(where: {
                Polygon.contains(SIMD2(position.x, position.z), in: $0.corners)
            }) { return floor.bottom }
            return self.rawCapture.hasMeasuredFloor(at: position) ? self.rawCapture.measuredFloorElevation(near: position) : nil
        }
        signObservations = []
        readSigns = []
        passiveSigns = []
        countedObservations = []
        let captureID = scanID
        rawCapture.onTextObservations = { [weak self] observations in
            guard let self, self.scanID == captureID else { return }
            self.signObservations = observations
            self.collectPassiveSigns(observations)
        }
        captureView = makeCaptureView()
        beginSection()
        beginResourceMonitoring()
        rawCapture.start(session: session)
        if AppConfig.recordScanVideo {
            let video = ScanVideoCapture()
            let id = scanID
            video.onStatus = { [weak self] status in
                guard let self, scanID == id, videoStatus != status else { return }
                videoStatus = status
            }
            video.onDepthAvailability = { [weak self] available in
                guard self?.scanID == id, !available else { return }
                self?.videoDepthNotice = "Some video frames have no LiDAR measurements."
            }
            videoCapture = video
            do { try video.start(session: session, captureID: scanID, floor: currentFloor) }
            catch { videoStatus = "Video couldn't start. Scanning can continue." }
        }
        if detailRequested { splatCapture.start(session: session) }
        detector.start(session: session)
        elevationMonitor.start()
        startViewTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureStartView() }
        }
    }

    func finish() {
        guard phase == .scanning || phase == .interrupted else { return }
        if pendingFloor == nil {
            elevationMonitor.stop()
            isChangingFloors = false
            proposedFloorLevel = nil
        }
        // An interrupted final room may still be held in memory after a processing or
        // storage failure. Retry it before finalizing so Finish never silently omits it.
        if phase == .interrupted {
            if let pendingRoomData {
                finishAfterProcessing = true
                pauseAfterProcessing = false
                errorMessage = nil
                phase = .processing
                sectionEnded(pendingRoomData, error: nil)
            } else if !rooms.isEmpty {
                saveWorldMap()
            }
        } else {
            endSection(thenFinish: true)
        }
    }

    /// Starts another section after RoomPlan ended one by itself.
    func continueScanning() {
        guard isActive, phase == .interrupted, !isChangingFloors, pendingFloor == nil else { return }
        guard ProcessInfo.processInfo.thermalState != .critical else {
            errorMessage = "Let the phone cool down before continuing. You can finish and save this map now."
            return
        }
        // A resource pause can stop AR tracking. Resume its existing configuration without
        // resetting the shared frame, then require fresh tracking before capturing again.
        if let configuration = session.configuration,
           session.currentFrame.map({ abs(ProcessInfo.processInfo.systemUptime - $0.timestamp) >= 1 }) ?? true {
            session.run(configuration, options: [])
        }
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1 else {
            errorMessage = "Move slowly in the same area while positioning recovers, then resume."
            return
        }
        errorMessage = nil
        if let pendingRoomData {
            finishAfterProcessing = false
            pauseAfterProcessing = false
            phase = .processing
            sectionEnded(pendingRoomData, error: nil)
            return
        }
        startSection()
    }

    func requestFloorChange() {
        guard let currentFloor, phase == .scanning || phase == .interrupted else { return }
        proposedFloorLevel = currentFloor.level + 1
    }

    func cancelFloorChange() {
        let shouldResume = floorChangePausedCapture
        proposedFloorLevel = nil
        pendingFloor = nil
        finishAfterProcessing = false
        isChangingFloors = false
        floorChangePausedCapture = false
        elevationMonitor.rebase()
        if shouldResume, errorMessage == nil, ProcessInfo.processInfo.thermalState != .critical {
            if phase == .processing { pauseAfterProcessing = false }
            else if phase == .interrupted { continueScanning() }
        }
    }

    func confirmFloorChange(to floor: ScanFloorIdentity) {
        guard let currentFloor, floor.buildingID == currentFloor.buildingID,
              floor.id != currentFloor.id, floor.level != currentFloor.level,
              phase == .scanning || phase == .processing || phase == .interrupted else { return }
        pendingFloor = floor
        proposedFloorLevel = nil
        isChangingFloors = true
        if phase == .processing {
            rawCapture.pause()
            videoCapture?.pause()
            finishAfterProcessing = true
        } else { finish() }
    }

    private func pauseForFloorChange() {
        guard isActive, phase == .scanning || phase == .processing || phase == .interrupted else { return }
        isChangingFloors = true
        if phase == .scanning {
            floorChangePausedCapture = true
            endSection(thenFinish: false, pauseAfter: true)
        } else if phase == .processing {
            // Evidence on this floor ends as soon as travel to another floor begins.
            rawCapture.pause()
            floorChangePausedCapture = !pauseAfterProcessing
            videoCapture?.pause()
            pauseAfterProcessing = true
        }
    }

    /// Captures the session's map of visual features. Also the retry when a capture fails.
    func saveWorldMap() {
        guard isActive else { return }
        // Final positioning recovery must not extend the completed floor's recorded walk.
        rawCapture.pause()
        videoCapture?.pause()
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
        elevationMonitor.stop()
        floorSwitchTask?.cancel()
        floorSwitchTask = nil
        worldMapRequestID = UUID()
        sectionRequestID = UUID()
        sectionTask?.cancel()
        sectionTask = nil
        pendingRoomData = nil
        pendingRoomSourceID = nil
        resourceTimer?.invalidate()
        resourceTimer = nil
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        startViewTimer?.invalidate()
        startViewTimer = nil
        previewMonitor?.invalidate()
        previewMonitor = nil
        detector.pause()
        rawCapture.stop()
        videoCapture?.stop()
        splatCapture.stop()
        sceneTask?.cancel()
        detailTask?.cancel()
        analysisTask?.cancel()
        reportTask?.cancel()
        captureSession?.delegate = nil
        if phase == .scanning || phase == .processing { captureSession?.stop() }
        captureSession = nil
        sessionDelegate?.discardRoomUpdates()
        sessionDelegate = nil
        captureView?.stop()
        captureView = nil
        roomTransitions.reset()
        livePortals = []
        liveFloors = []
        if phase != .unsupported { session.pause() }
    }

    func addPoint(_ kind: AccessPoint.Kind, at floorPoint: SIMD2<Float>, name: String? = nil) {
        guard canPlaceReviewPoints, let floorY = draft?.floorY else { return }
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
        guard let draft, let worldMap, scene != nil else {
            throw CaptureValidationError.invalid("This floor isn't ready to save yet.")
        }
        // Build against the exact saved draft, even if its debounced review report is still pending.
        let report = try await ScanWork.run { try AccessibilityReport.make(map: draft) }
        try await stageReviewedSemantics(draft)
        // A fast Save still retains the optional display derived from this floor's originals.
        if let detailTask { await detailTask.value }
        try Task.checkCancellation()
        try await MapStore.save(draft, report: report, rooms: rooms, worldMap: worldMap, startView: startView,
                                floor: currentFloor, buildingName: buildingName, captureID: captureBundle?.id)
    }

    private var measurementTimestamps: [UUID: TimeInterval] {
        Dictionary(uniqueKeysWithValues: detector.sightings.compactMap { sighting in
            sighting.measurementTimestamp.map { (sighting.id, $0) }
        })
    }

    private func stageReviewedSemantics(_ map: VenueMap) async throws {
        guard let bundle = captureBundle else { return }
        let rooms = rooms
        let info = SemanticExport.captureInfo(floorID: bundle.floorID)
        let timestamps = measurementTimestamps
        try await ScanWork.run {
            try SemanticExport.stageSemantics(map: map, rooms: rooms, capture: info,
                                               captureID: bundle.id, measurementTimestamps: timestamps)
            let raw = try CaptureStore.loadRawSnapshot(id: bundle.id)
            SemanticExport.stageCapturedText(raw: raw, captureID: bundle.id, reference: map.geographicReference)
        }
    }

    /// Explicit review is the only action that sends this local capture for processing.
    func findPlaces() {
        guard phase == .review, !isFindingPlaces, let map = draft, let bundle = captureBundle else { return }
        guard let baseURL = AppConfig.backendURL else {
            analysisError = "Add a scan server in Settings first."
            return
        }
        let client = BackendClient(baseURL: baseURL, accessToken: AppConfig.backendToken)
        let id = scanID
        let sourceRooms = rooms
        let info = SemanticExport.captureInfo(floorID: bundle.floorID)
        let timestamps = measurementTimestamps
        let revision = draftRevision
        let retryID = pendingAnalysis.flatMap { $0.server == baseURL ? $0.scanID : nil }
        analysisError = nil
        analysisStatus = "Preparing scan…"
        isFindingPlaces = true
        analysisTask = Task { [weak self] in
            defer {
                if self?.scanID == id { self?.isFindingPlaces = false; self?.analysisTask = nil }
            }
            do {
                guard let self, self.isActive, self.scanID == id else { return }
                let requestID: String
                if let retryID {
                    requestID = retryID
                } else {
                    let package = try await ScanWork.run {
                        // Refresh from this exact reviewed draft before making its immutable upload.
                        try SemanticExport.stageSemantics(map: map, rooms: sourceRooms, capture: info,
                            captureID: bundle.id, measurementTimestamps: timestamps)
                        let raw = try CaptureStore.loadRawSnapshot(id: bundle.id)
                        SemanticExport.stageTextObservations(raw: raw, map: map, floorID: bundle.floorID, captureID: bundle.id)
                        return try CaptureStore.makeAnalysisPackage(bundle)
                    }
                    defer { try? FileManager.default.removeItem(at: package.archiveURL.deletingLastPathComponent()) }
                    try Task.checkCancellation()
                    guard self.isActive, self.scanID == id else { return }
                    self.analysisStatus = "Sending scan…"
                    try await client.uploadArchive(at: package.archiveURL, capture: package.capture)
                    requestID = package.capture.id
                    if self.draftRevision == revision { self.pendingAnalysis = (requestID, baseURL) }
                }
                self.analysisStatus = "Finding places…"
                // Processing is bounded and retryable; remote geometry is never adopted here.
                for _ in 0..<60 {
                    try Task.checkCancellation()
                    if let analysis = try await client.analysis(scanID: requestID) {
                        guard self.isActive, self.scanID == id else { return }
                        self.pendingAnalysis = nil
                        guard self.draftRevision == revision else {
                            self.analysisStatus = "The map changed. Find places again to include your edits."
                            return
                        }
                        let existing = Set(self.draft?.points.map(\.id) ?? [])
                        var seen = Set<String>()
                        self.analysisCandidates = analysis.places.filter { place in
                            seen.insert(place.id).inserted && !self.reviewedAnalysisIDs.contains(place.id)
                                && !(place.sourceAccessPointID.map { existing.contains($0) } ?? false)
                        }
                        self.analysisHighlights = analysis.highlights.flatMap { $0.items.isEmpty ? nil : $0 }
                        self.analysisStatus = self.analysisCandidates.isEmpty
                            ? "No new places found." : "Review each place before adding it."
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
                self.analysisStatus = nil
                self.analysisError = "The scan server is still working. Try again in a moment."
            } catch {
                guard !Task.isCancelled, self?.scanID == id else { return }
                if let backendError = error as? BackendClientError,
                   case .http(404, "scan_not_found", _) = backendError {
                    self?.pendingAnalysis = nil
                }
                self?.analysisStatus = nil
                self?.analysisError = error.localizedDescription
            }
        }
    }

    /// Keeps a sign the mapper read; the same sign read again replaces the earlier reading.
    func forgetSign(id: UUID) {
        readSigns.removeAll { $0.id == id }
    }

    func recordSign(_ sighting: SignReader.Sighting) {
        readSigns.removeAll { $0.reading.title == sighting.reading.title && simd_distance($0.position, sighting.position) < 1 }
        readSigns.append(sighting)
    }

    /// Labels the finished map's doors from signs: every sign the mapper read, plus room, exit and
    /// restroom text the scan's keyframes read on their own when it was seen twice or sits by a door.
    /// All of them stay editable in review like any other destination.
    private func collectPassiveSigns(_ observations: [CaptureTextObservation]) {
        let viewer = session.currentFrame?.camera.transform.translation
        for observation in observations {
            guard countedObservations.insert(observation.frameID + "|" + observation.text).inserted,
                  let spatial = observation.spatial, let reading = SignInterpreter.interpret([observation.text]),
                  !reading.isDirectional, reading.category != .other else { continue }
            if let index = passiveSigns.firstIndex(where: { $0.reading.title == reading.title && simd_distance($0.position, spatial.position) < 1 }) {
                passiveSigns[index].count += 1
                // The longer reading of the same plate ("204" then "204 Meeting Room") is the better one.
                if observation.text.count > passiveSigns[index].text.count {
                    passiveSigns[index].reading = reading; passiveSigns[index].text = observation.text
                }
            } else {
                passiveSigns.append((reading, observation.text, spatial.position, viewer, 1))
            }
        }
    }

    private func applySigns(to map: inout VenueMap) {
        for sighting in readSigns {
            let point = SignPlaceBinder.place(for: sighting.reading, text: sighting.text, sign: sighting.position,
                                              viewer: sighting.viewer, in: map, id: sighting.id)
            map.applySign(point.withReader(sighting.check))
        }
        // A place sign read once is still worth a door: the interpreter already turned away posters and notices.
        for cluster in passiveSigns {
            // An explicit reading of the same sign wins over the passive one.
            guard !readSigns.contains(where: { simd_distance($0.position, cluster.position) < 1 }) else { continue }
            map.applySign(SignPlaceBinder.place(for: cluster.reading, text: cluster.text, sign: cluster.position,
                                                viewer: cluster.viewer, in: map, confidence: 0.75))
        }
    }

    func canKeepAnalysisPlace(_ place: ScanAnalysis.Place) -> Bool {
        guard let draft, let bundle = captureBundle else { return false }
        return place.accessPoint(scanID: bundle.id, floorY: draft.floorY, expectedFloorID: bundle.floorID) != nil
    }

    func keepAnalysisPlace(_ place: ScanAnalysis.Place) {
        guard var map = draft, let bundle = captureBundle,
              let point = place.accessPoint(scanID: bundle.id, floorY: map.floorY, expectedFloorID: bundle.floorID)
        else { return }
        // A phone observation may already be a reviewed point. Preserve all of that point's edits.
        if !map.points.contains(where: { $0.id == point.id }) { MapBuilder.add(point, to: &map) }
        draft = map
        dropAnalysisPlace(place)
    }

    func dropAnalysisPlace(_ place: ScanAnalysis.Place) {
        reviewedAnalysisIDs.insert(place.id)
        analysisCandidates.removeAll { $0.id == place.id }
    }

    var canRetryDetail: Bool { rawArchived && captureBundle != nil && !isPreparingDetail && detailRequested }

    func retryDetail() {
        guard canRetryDetail, let bundle = captureBundle else { return }
        prepareDetail(bundle)
    }

    private func prepareDetail(_ bundle: CaptureBundle) {
        guard detailRequested else { return }
        let id = scanID
        detailError = nil
        isPreparingDetail = true
        detailTask = Task { [weak self] in
            defer {
                if self?.scanID == id { self?.isPreparingDetail = false; self?.detailTask = nil }
            }
            do {
                let result = try await ScanWork.run {
                    // Never compact or color the sole copy of the native scan.
                    let raw = try CaptureStore.loadRawSnapshot(id: bundle.id)
                    let rebuilt = try RawScanCapture.reconstruct(raw)
                    guard let mesh = rebuilt.meshes.first else {
                        throw CaptureValidationError.invalid("No additional detail was captured. The room map is ready to use.")
                    }
                    var detail = bundle
                    detail.meshes = [mesh]
                    let plain = try LocalSceneBuilder.make(from: detail, includeDepthPoints: false)
                    try CaptureStore.saveDetailScene(plain, for: detail)
                    return (detail, plain, raw)
                }
                try Task.checkCancellation()
                guard let self, self.isActive, self.scanID == id else { return }
                self.detailScene = result.1
                // Color is a separate retryable stage; the gray model and canonical map already exist.
                let colored = try await ScanWork.run {
                    var detail = result.0
                    guard let mesh = detail.meshes.first,
                          let color = try MeshColorizer.color(mesh, frames: result.2.frames,
                                                              colors: result.2.colorKeyframes ?? []) else { return result.1 }
                    detail.meshes = [color.mesh]
                    let scene = try LocalSceneBuilder.make(from: detail, includeDepthPoints: false)
                    try CaptureStore.saveDetailScene(scene, for: detail)
                    return scene
                }
                guard !Task.isCancelled, self.isActive, self.scanID == id else { return }
                self.detailScene = colored
            } catch {
                guard !Task.isCancelled, self?.scanID == id else { return }
                self?.detailError = error.localizedDescription
            }
        }
    }

    func retryScene() {
        guard canRetryScene, !isProcessingScene else { return }
        prepareScene()
    }

    func useLocalScene() {
        guard canUseLocalScene, let captureBundle else { return }
        processScene(captureBundle)
    }

    private func endSection(thenFinish finish: Bool, pauseAfter: Bool = false) {
        guard isActive, phase == .scanning else { return }
        finishAfterProcessing = finish
        pauseAfterProcessing = pauseAfter
        phase = .processing
        detector.pause()
        previewMonitor?.invalidate()
        previewMonitor = nil
        roomTransitions.suspend()
        livePortals = []
        if !finish && !pauseAfter {
            // Walking out of a room: keep the walk, floor and video going while it saves.
            rawCapture.observeFloorDuringHandoff()
        } else {
            rawCapture.pause()
            videoCapture?.pause()
        }
        splatCapture.pause()
        // Keep the AR session running so the next section and the world map share its coordinates.
        captureSession?.stop(pauseARSession: false)
        sessionDelegate?.discardRoomUpdates()
        captureView?.clearRoom()
    }

    /// Runs a RoomPlan capture for a new section and resets what's remembered about the live room.
    private func beginSection() {
        guard isActive, let captureSession else { return }
        captureView?.clearRoom()
        sessionDelegate?.discardRoomUpdates()
        liveFloors = []
        livePortals = []
        roomTransitions.suspend()
        roomInstruction = nil
        previewMonitor?.invalidate()
        captureSession.run(configuration: RoomCaptureSession.Configuration())
        previewMonitor = Timer.scheduledTimer(withTimeInterval: Self.previewMonitorInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let room = self?.sessionDelegate?.takeLatestRoom() { self?.liveRoomUpdated(room) }
                self?.updateScanGuidance()
            }
        }
    }

    private func liveRoomUpdated(_ room: CapturedRoom) {
        guard isActive, phase == .scanning else { return }
        let frame = session.currentFrame
        let observedAt: TimeInterval?
        if let frame, case .normal = frame.camera.trackingState,
           abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1 {
            observedAt = frame.timestamp
        } else { observedAt = nil }
        captureView?.update(room: room, observedAt: observedAt)
    }

    private func applyLiveRoomMeasurements(_ measurements: ScanLiveRoomMeasurements) {
        guard isActive, phase == .scanning else { return }
        if let floorY = measurements.floorY { rawCapture.floorY = floorY }
        liveFloors = measurements.floors
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1,
              let observedAt = measurements.observedAt,
              abs(ProcessInfo.processInfo.systemUptime - observedAt) < 1 else {
            livePortals = []
            roomTransitions.suspend()
            return
        }
        livePortals = measurements.portals
    }

    /// Refresh capture guidance without ending the scan as the mapper moves between rooms.
    private func updateScanGuidance() {
        guard isActive, phase == .scanning, !isChangingFloors, pendingFloor == nil,
              let frame = session.currentFrame else { roomTransitions.suspend(); return }
        let normal: Bool
        if case .normal = frame.camera.trackingState {
            normal = abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1
        } else { normal = false }
        // @Published fires on every write; equal values would still redraw the scan screen five times a second.
        let notice = normal ? nil : "Move slowly while positioning recovers."
        if trackingNotice != notice { trackingNotice = notice }
        let position = frame.camera.transform.translation
        let floorObserved = rawCapture.hasMeasuredFloor(at: position)
            || liveFloors.contains { Polygon.contains(SIMD2(position.x, position.z), in: $0.corners) }
        let guidance = roomInstruction.flatMap {
            ProcessInfo.processInfo.systemUptime - roomInstructionTime < 4 ? $0 : nil
        } ?? (floorObserved ? "Keep moving slowly and include the floor."
                           : "Tilt down to capture the floor around you.")
        if scanGuidance != guidance { scanGuidance = guidance }
        checkDoorways(position: position, timestamp: frame.timestamp, trackingIsNormal: normal)
    }

    /// Ends the room once the mapper has walked out through one of its measured doors or openings.
    private func checkDoorways(position: SIMD3<Float>, timestamp: TimeInterval, trackingIsNormal: Bool) {
        // A guessed phone height can reject real doors in a corridor whose floor RoomPlan
        // missed, so use the floor ARKit measured near the mapper.
        guard let floorY = rawCapture.measuredFloorElevation(near: position) else {
            roomTransitions.suspend()
            return
        }
        guard roomTransitions.update(portals: livePortals, position: position, floorY: floorY,
                                     timestamp: timestamp, trackingIsNormal: trackingIsNormal) != nil else { return }
        Log.scan.notice("walked out through a doorway; saving the room and starting the next")
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        endSection(thenFinish: false)
    }

    private func updateInstruction(_ instruction: RoomCaptureSession.Instruction) {
        guard isActive, phase == .scanning else { return }
        switch instruction {
        case .moveCloseToWall: roomInstruction = "Move a little closer to the wall."
        case .moveAwayFromWall: roomInstruction = "Step back to see more of the wall."
        case .slowDown: roomInstruction = "Slow down so the room can be captured."
        case .turnOnLight: roomInstruction = "More light will help capture this room."
        case .lowTexture: roomInstruction = "Include a doorway or other detail in view."
        case .normal: roomInstruction = nil
        @unknown default: roomInstruction = nil
        }
        roomInstructionTime = ProcessInfo.processInfo.systemUptime
    }

    private func sectionProcessed(_ room: CapturedRoom) {
        guard isActive else { return }
        switch phase {
        case .processing:
            rooms.append(room)
            Log.scan.notice("section \(self.rooms.count) processed: \(room.walls.count) walls, \(room.doors.count) doors, \(room.objects.count) objects")
            if finishAfterProcessing {
                saveWorldMap()
            } else if pauseAfterProcessing {
                rawCapture.pause()
                videoCapture?.pause()
                phase = .interrupted
                if ProcessInfo.processInfo.thermalState == .critical { session.pause() }
            } else {
                startSection()
            }
        default:
            Log.scan.notice("ignored a processed room while \(String(describing: self.phase), privacy: .public)")
        }
    }

    /// The session delegate supplies each section once, alongside its live updates.
    /// Process the immutable section separately from the bounded camera preview.
    private func sectionEnded(_ data: CapturedRoomData, error: Error?) {
        guard isActive, phase == .scanning || phase == .processing, sectionTask == nil else { return }
        previewMonitor?.invalidate()
        previewMonitor = nil
        roomTransitions.suspend()
        livePortals = []
        captureView?.clearRoom()
        let endedUnexpectedly = phase == .scanning
        if endedUnexpectedly {
            Log.scan.error("RoomPlan ended the active section: \(error?.localizedDescription ?? "no error reported", privacy: .public)")
            finishAfterProcessing = false
            pauseAfterProcessing = true
            phase = .processing
            detector.pause()
            rawCapture.pause()
            videoCapture?.pause()
            splatCapture.pause()
            if ProcessInfo.processInfo.thermalState == .critical {
                session.pause()
            } else if let configuration = session.configuration {
                session.run(configuration, options: [])
            }
        }
        if let error {
            rawCapture.pause()
            videoCapture?.pause()
            captureFailed(error)
            pauseAfterProcessing = true
        }
        let requestID = UUID()
        let sourceID = pendingRoomSourceID ?? UUID()
        pendingRoomData = data
        pendingRoomSourceID = sourceID
        sectionRequestID = requestID
        sectionTask = Task { [weak self] in
            var sourceArchived = false
            var failureStage = "original room archive"
            do {
                guard let scanID = self?.scanID else { return }
                do {
                    try await ScanWork.run {
                        try CaptureStore.stageRoomCaptureData(id: scanID.uuidString, roomID: sourceID,
                                                              value: data)
                    }
                    sourceArchived = true
                } catch let failure as RoomCaptureArchive.Failure {
                    guard case .encoding = failure else { throw failure }
                    try Task.checkCancellation()
                    guard self?.isActive == true, self?.sectionRequestID == requestID else { return }
                    // Opaque source serialization is optional; it must not prevent RoomBuilder
                    // from producing the room or completing the floor's scan.
                    self?.logRoomFailure(failure, stage: failureStage)
                    self?.originalScanWarning = "Some original sensor data is unavailable."
                }
                try Task.checkCancellation()
                guard self?.isActive == true, self?.sectionRequestID == requestID else { return }
                failureStage = "room processing"
                let builder = RoomBuilder(options: [.beautifyObjects])
                let room = try await builder.capturedRoom(from: data)
                try Task.checkCancellation()
                if !sourceArchived {
                    failureStage = "processed room archive"
                    do {
                        try await ScanWork.run {
                            try CaptureStore.stageProcessedRoom(id: scanID.uuidString, roomID: sourceID, value: room)
                        }
                    } catch let failure as RoomCaptureArchive.Failure {
                        guard case .encoding = failure else { throw failure }
                        try Task.checkCancellation()
                        guard self?.isActive == true, self?.sectionRequestID == requestID else { return }
                        self?.logRoomFailure(failure, stage: failureStage)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.isActive, self.sectionRequestID == requestID else { return }
                self.sectionTask = nil
                self.pendingRoomData = nil
                self.pendingRoomSourceID = nil
                self.sectionProcessed(room)
            } catch {
                guard !Task.isCancelled, let self, self.isActive, self.sectionRequestID == requestID else { return }
                self.sectionTask = nil
                self.rawCapture.pause()
                self.videoCapture?.pause()
                self.logRoomFailure(error, stage: failureStage)
                if let failure = error as? RoomCaptureArchive.Failure, case .storage = failure {
                    self.errorMessage = failure.isOutOfSpace
                        ? "There isn't enough storage to save this room. Free some space, then resume."
                        : "Couldn't save this room on this phone. Resume to try again."
                    self.interruptionAdvice = "This room is still held in memory. Resume to retry saving it before closing the scan."
                } else {
                    self.errorMessage = "Couldn't finish this room. Resume to try again."
                    self.interruptionAdvice = sourceArchived
                        ? "Your original capture is kept on this phone. Continue scanning or Finish will retry this room."
                        : "This room is still held in memory. Resume to retry before closing the scan."
                }
                self.phase = .interrupted
            }
        }
    }

    private func logRoomFailure(_ error: Error, stage: String) {
        let underlying = (error as? RoomCaptureArchive.Failure)?.underlyingError ?? error
        let diagnostic = underlying as NSError
        var reason = diagnostic.localizedDescription
        if let encodingError = underlying as? EncodingError, case .invalidValue(_, let context) = encodingError {
            reason = context.debugDescription + " at " + context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        Log.scan.error("\(stage, privacy: .public) failed: \(diagnostic.domain, privacy: .public) code \(diagnostic.code); \(reason, privacy: .private)")
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
        if appIsActive { videoCapture?.resume() }
        if detailRequested { splatCapture.resume() }
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
        rawCapture.captureReconstructedMesh(from: session)
        session.pause()
        captureSession?.delegate = nil
        captureSession = nil
        sessionDelegate?.discardRoomUpdates()
        sessionDelegate = nil
        captureView?.stop()
        captureView = nil
        resourceTimer?.invalidate()
        resourceTimer = nil
        unconfirmed = detector.unconfirmedSightings()
        prepareScene()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Archive the sources first, then prepare one authoritative on-device structure.
    private func prepareScene() {
        let sourceRooms = rooms
        let points = detector.accessPoints()
        let stairs = detector.stairsFootprints()
        let id = scanID
        let floor = currentFloor
        sceneError = nil
        sceneStage = .preparing
        phase = .processingScene
        isProcessingScene = true
        sceneTask = Task { [weak self] in
            defer { self?.isProcessingScene = false }
            do {
                guard let self else { return }
                await videoCapture?.finish()
                let raw: RawScanSnapshot
                if let retained = finishedRawSnapshot { raw = retained }
                else if rawArchived {
                    raw = try await ScanWork.run { try CaptureStore.loadRawSnapshot(id: id.uuidString) }
                } else {
                    raw = await rawCapture.finishSnapshot()
                    finishedRawSnapshot = raw
                }
                try Task.checkCancellation()
                guard isActive, scanID == id else { return }
                let nativeArchiveWarning = try await ScanWork.run { () -> String? in
                    let rawData = try ScanExporter.rawSnapshotData(raw)
                    try CaptureStore.stageRawSnapshot(id: id.uuidString, data: rawData)
                    SemanticExport.stageCapturedText(raw: raw, captureID: id.uuidString)
                    do {
                        try CaptureStore.stageNativeRooms(id: id.uuidString, rooms: sourceRooms)
                        return nil
                    } catch let failure as RoomCaptureArchive.Failure {
                        guard case .encoding = failure else { throw failure }
                        Log.scan.error("couldn't serialize native rooms: \(failure.underlyingError.localizedDescription, privacy: .private)")
                        return "Some original room data is unavailable."
                    }
                }
                try Task.checkCancellation()
                guard isActive, scanID == id else { return }
                rawArchived = true
                finishedRawSnapshot = nil
                if let nativeArchiveWarning { originalScanWarning = nativeArchiveWarning }
                let originalWarning = originalScanWarning
                if detailRequested { splatCapture.finish(meshes: []) }
                sceneStage = .reconstructing
                let assembled = try await RoomPlanAssembly.prepare(rooms: sourceRooms, raw: raw,
                    scanID: id, mapID: id, floor: floor, points: points, spottedStairs: stairs)
                try Task.checkCancellation()
                let walkCoverage = try await ScanWork.run {
                    raw.walkTrace.map { ScanWalkFloorCoverage.assess(trace: $0, map: assembled.map) }
                }
                sceneStage = .saving
                let finalScene = try await ScanWork.run {
                    var result = try LocalSceneBuilder.make(from: assembled.bundle, includeDepthPoints: false)
                    if let originalWarning { result.warnings.append(originalWarning) }
                    try CaptureStore.stageBundle(assembled.bundle)
                    do { try CaptureStore.stageEvidence(raw, id: id.uuidString) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        // Supporting recognition evidence must not invalidate usable RoomPlan geometry.
                        result.warnings.append("Some supporting scan evidence couldn't be saved. The room map is ready to use.")
                        Log.scan.error("couldn't stage scan evidence: \(error.localizedDescription, privacy: .public)")
                    }
                    if let structure = assembled.structure {
                        do { try CaptureStore.stageRoomStructure(id: id.uuidString, structure: structure) }
                        catch let failure as RoomCaptureArchive.Failure {
                            guard case .encoding = failure else { throw failure }
                            result.warnings.append("Some original room data is unavailable.")
                            Log.scan.error("couldn't serialize native structure: \(failure.underlyingError.localizedDescription, privacy: .private)")
                        }
                    }
                    try CaptureStore.saveScene(result, for: assembled.bundle)
                    return result
                }
                try Task.checkCancellation()
                guard isActive, scanID == id else { return }
                // The map and display come from the same successful assembly; failures publish neither.
                rooms = assembled.rooms
                var reviewed = assembled.map
                applySigns(to: &reviewed)
                draft = reviewed
                walkTrace = raw.walkTrace
                self.walkCoverage = walkCoverage
                captureBundle = assembled.bundle
                localScene = finalScene
                scene = finalScene
                if finalScene.warnings.contains("Some original room data is unavailable.") {
                    originalScanWarning = "Some original room data is unavailable."
                }
                do { try await stageReviewedSemantics(assembled.map) }
                catch is CancellationError { throw CancellationError() }
                catch { analysisError = "Some place details couldn't be saved. Find places will try again." }
                prepareDetail(assembled.bundle)
            } catch {
                if !Task.isCancelled {
                    self?.logRoomFailure(error, stage: "map preparation")
                    if RoomCaptureArchive.Failure.storage(error).isOutOfSpace
                        || (error as? RoomCaptureArchive.Failure)?.isOutOfSpace == true {
                        self?.sceneError = "There isn't enough storage to prepare this map. Free some space, then try again."
                    } else if let failure = error as? RoomCaptureArchive.Failure, case .storage = failure {
                        self?.sceneError = "Couldn't save this scan on this phone. Try again."
                    } else if error is EncodingError {
                        self?.sceneError = "Some scan measurements couldn't be read. Try preparing the map again."
                    } else {
                        self?.sceneError = error.localizedDescription
                    }
                }
            }
            if !Task.isCancelled {
                self?.phase = .review
                if self?.pendingFloor != nil, self?.scene != nil { self?.completeFloorSwitch() }
            }
        }
    }

    /// Publish the previous floor before starting a fresh scan and coordinate frame upstairs.
    private func completeFloorSwitch() {
        guard let nextFloor = pendingFloor, floorSwitchTask == nil else { return }
        phase = .switchingFloor
        floorSwitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await save()
                try Task.checkCancellation()
                guard isActive else { return }
                reportTask?.cancel()
                analysisTask?.cancel()
                detailTask?.cancel()
                detector.pause()
                rawCapture.stop()
                videoCapture = nil
                videoStatus = nil
                videoDepthNotice = nil
                splatCapture.stop()
                trackingNotice = nil
                scanGuidance = "Move slowly and include the floor as you scan."
                originalScanWarning = nil
                session.pause()
                session = ARSession()
                detector = AccessibilityDetector()
                rawCapture = RawScanCapture()
                scanID = UUID()
                // Every floor has its own photo archive in that floor's scan coordinates.
                splatCapture = SplatCapture(scanID: scanID)
                currentFloor = nextFloor
                pendingFloor = nil
                rooms = []
                liveFloors = []
                roomInstruction = nil
                pendingRoomData = nil
                pendingRoomSourceID = nil
                worldMap = nil
                startView = nil
                unconfirmed = []
                captureBundle = nil
                localScene = nil
                finishedRawSnapshot = nil
                rawArchived = false
                scene = nil
                detailScene = nil
                detailError = nil
                isPreparingDetail = false
                analysisCandidates = []
                analysisHighlights = nil
                analysisStatus = nil
                analysisError = nil
                isFindingPlaces = false
                reviewedAnalysisIDs = []
                draft = nil
                report = nil
                walkTrace = nil
                walkCoverage = nil
                errorMessage = nil
                sceneError = nil
                isChangingFloors = false
                floorChangePausedCapture = false
                hasStarted = false
                finishAfterProcessing = false
                pauseAfterProcessing = false
                floorSwitchTask = nil
                elevationMonitor.rebase()
                phase = .scanning
                start()
            } catch {
                guard !Task.isCancelled else { return }
                floorSwitchTask = nil
                errorMessage = "Couldn't save \(currentFloor?.name ?? "this floor"). \(error.localizedDescription)"
                phase = .review
            }
        }
    }

    var nextFloorName: String? { pendingFloor?.name }

    func retryFloorSwitch() {
        if scene == nil { retryScene() }
        else { completeFloorSwitch() }
    }

    private func processScene(_ bundle: CaptureBundle) {
        sceneError = nil
        sceneStage = .preparing
        isProcessingScene = true
        sceneTask = Task { [weak self] in
            defer { self?.isProcessingScene = false }
            do {
                let result = try await ScanWork.run {
                    let scene = try LocalSceneBuilder.make(from: bundle, includeDepthPoints: false)
                    try CaptureStore.saveScene(scene, for: bundle)
                    return scene
                }
                try Task.checkCancellation()
                guard let self, isActive else { return }
                scene = result
            } catch {
                if !Task.isCancelled { self?.sceneError = error.localizedDescription }
            }
            if !Task.isCancelled { self?.phase = .review }
        }
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

    var canFinishInterruptedScan: Bool {
        !rooms.isEmpty || pendingRoomData != nil
    }

    var interruptionHint: String {
        if pendingRoomData != nil { return interruptionAdvice }
        return rooms.isEmpty ? "Continue when ready to finish this room." : "Your completed rooms are kept. \(interruptionAdvice)"
    }

    private func captureFailed(_ error: Error) {
        guard isActive else { return }
        errorMessage = error.localizedDescription
        switch error as? RoomCaptureSession.CaptureError {
        case .deviceTooHot:
            errorMessage = "The phone needs to cool down. You can finish and save what you've scanned."
            interruptionAdvice = "Let the phone cool down before continuing, or finish and save now."
        case .exceedSceneSizeLimit:
            errorMessage = "RoomPlan reached its limit for this room. Scanning has paused."
            interruptionAdvice = "Your capture is kept. Finish and review it, or resume when ready."
        default:
            interruptionAdvice = "Move somewhere with more detail in view, then continue, or finish with what you have."
        }
    }

    private func beginResourceMonitoring() {
        resourceTimer?.invalidate()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
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
            scanNotice = "The phone is warming up. Consider taking a short break."
        default:
            scanNotice = nil
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
        let id = scanID
        Task { [weak self] in
            let jpeg = await Task.detached(priority: .utility) { FrameEncoder.portraitJPEG(from: snapshot, maxDimension: 720) }.value
            guard self?.scanID == id, self?.isActive == true else { return }
            self?.startView = jpeg
        }
    }
}

/// Coalesces live measurements instead of queuing a main-actor task for every growing room.
/// Final capture data is forwarded separately and is never dropped by preview throttling.
final class CaptureSessionDelegate: NSObject, RoomCaptureSessionDelegate {
    private let roomLock = NSLock()
    private var latestRoom: CapturedRoom?
    private let onStart: @MainActor () -> Void
    private let onEnd: @MainActor (CapturedRoomData, Error?) -> Void
    private let onInstruction: @MainActor (RoomCaptureSession.Instruction) -> Void

    init(onStart: @escaping @MainActor () -> Void = {},
         onEnd: @escaping @MainActor (CapturedRoomData, Error?) -> Void,
         onInstruction: @escaping @MainActor (RoomCaptureSession.Instruction) -> Void) {
        self.onStart = onStart
        self.onEnd = onEnd
        self.onInstruction = onInstruction
    }

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        Task { @MainActor in onStart() }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        roomLock.withLock { latestRoom = room }
    }

    // didAdd/didChange/didRemove contain partial changes. Only didUpdate supplies a
    // complete room snapshot that can safely replace the pending display measurements.

    func takeLatestRoom() -> CapturedRoom? {
        roomLock.withLock {
            defer { latestRoom = nil }
            return latestRoom
        }
    }

    func discardRoomUpdates() { roomLock.withLock { latestRoom = nil } }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in onInstruction(instruction) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in onEnd(data, error) }
    }
}
