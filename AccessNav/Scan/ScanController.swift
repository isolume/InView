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
        case savingWorldMap
        case processingScene
        case review
    }

    @Published private(set) var phase: Phase
    @Published private(set) var sectionCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var draft: VenueMap?
    @Published private(set) var scene: ProcessedScene?
    @Published private(set) var sceneError: String?
    @Published private(set) var isProcessingScene = false

    let session = ARSession()
    let detector = AccessibilityDetector()
    private let rawCapture = RawScanCapture()
    private let scanID = UUID()
    private var captureBundle: CaptureBundle?
    private var sceneTask: Task<Void, Never>?
    var canRetryScene: Bool { captureBundle != nil }

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

    func finish() { endSection(thenFinish: true) }

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
        if phase == .scanning { captureView.captureSession.stop() }
        if phase != .unsupported { session.pause() }
    }

    func addPoint(_ kind: AccessPoint.Kind, at floorPoint: SIMD2<Float>, name: String? = nil) {
        guard let floorY = draft?.floorY else { return }
        let position = SIMD3(floorPoint.x, floorY, floorPoint.y)
        draft?.points.append(AccessPoint(kind: kind, name: name, position: position, source: .manual, confidence: 1))
    }

    func removePoints(at offsets: IndexSet) {
        draft?.points.remove(atOffsets: offsets)
    }

    func save() throws {
        guard let draft, let worldMap else { return }
        try MapStore.save(draft, rooms: rooms, worldMap: worldMap, startView: startView)
        if let captureBundle { try CaptureStore.select(captureBundle) }
        else { CaptureStore.clearSelection() }
    }

    func retryScene() {
        guard !isProcessingScene, let captureBundle else { return }
        processScene(captureBundle)
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
        guard phase == .processing else { return }
        rooms.append(room)
        sectionCount = rooms.count
        if finishAfterProcessing {
            saveWorldMap()
        } else {
            phase = .scanning
            captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
            detector.resume()
            rawCapture.resume()
        }
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
        draft = MapBuilder.build(rooms: rooms, points: detector.accessPoints())
        do {
            let snapshot = rawCapture.snapshot()
            let rawData = try ScanExporter.rawSnapshotData(snapshot)
            let roomData = try ScanExporter.nativeRoomPlanData(rooms: rooms)
            try CaptureStore.stageOriginals(id: scanID.uuidString, rawData: rawData, roomPlanData: roomData)
            let bundle = try ScanExporter.bundle(rooms: rooms, raw: snapshot, scanID: scanID, mapID: scanID)
            try CaptureStore.stage(bundle, rawData: rawData, roomPlanData: roomData)
            captureBundle = bundle
            phase = .processingScene
            processScene(bundle)
        } catch {
            sceneError = error.localizedDescription
            phase = .review
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func processScene(_ bundle: CaptureBundle) {
        sceneError = nil
        guard let url = AppConfig.backendURL else {
            sceneError = "Set your room processing server in Settings to build the 3D view. The scan is saved on this device."
            phase = .review
            return
        }
        isProcessingScene = true
        sceneTask = Task { [weak self] in
            defer { self?.isProcessingScene = false }
            do {
                let result = try await BackendClient(baseURL: url).uploadAndProcess(bundle)
                try Task.checkCancellation()
                try CaptureStore.saveScene(result, for: bundle)
                self?.scene = result
            } catch {
                if !Task.isCancelled { self?.sceneError = error.localizedDescription }
            }
            if !Task.isCancelled { self?.phase = .review }
        }
    }

    private func captureStartView() {
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState else { return }
        startView = FrameEncoder.portraitJPEG(from: frame.capturedImage, maxDimension: 720)
        startViewTimer?.invalidate()
        startViewTimer = nil
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
