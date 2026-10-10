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
        case review
    }

    @Published private(set) var phase: Phase
    @Published private(set) var sectionCount = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var draft: VenueMap? {
        didSet { scheduleReport() }
    }
    @Published private(set) var report: AccessibilityReport?
    /// Finds the camera placed but didn't see often enough to count. Review asks about each one.
    @Published private(set) var unconfirmed: [AccessibilityDetector.Sighting] = []

    let session = ARSession()
    let detector = AccessibilityDetector()

    private(set) lazy var captureView: RoomCaptureView = {
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
        if phase == .scanning { captureView.captureSession.stop() }
        if phase != .unsupported { session.pause() }
    }

    func addPoint(_ kind: AccessPoint.Kind, at floorPoint: SIMD2<Float>) {
        guard let floorY = draft?.floorY else { return }
        let position = SIMD3(floorPoint.x, floorY, floorPoint.y)
        draft?.points.append(AccessPoint(kind: kind, position: position, source: .manual, confidence: 1))
    }

    func removePoints(at offsets: IndexSet) {
        draft?.points.remove(atOffsets: offsets)
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = draft?.points.firstIndex(where: { $0.id == id }) else { return }
        draft?.points[index].name = name
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

    func save() throws {
        guard let draft, let worldMap else { return }
        let report = report ?? AccessibilityReport(map: draft)
        try MapStore.save(draft, report: report, rooms: rooms, worldMap: worldMap, startView: startView)
    }

    private func endSection(thenFinish finish: Bool) {
        guard phase == .scanning else { return }
        finishAfterProcessing = finish
        phase = .processing
        detector.pause()
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
        }
    }

    private func worldMapCaptured(_ worldMap: ARWorldMap?, error: Error?) {
        guard phase == .savingWorldMap else { return }
        guard let worldMap else {
            errorMessage = "Couldn't capture the AR map (\(error?.localizedDescription ?? "unknown error")). Move the phone slowly around the area and try again."
            return
        }
        self.worldMap = worldMap
        session.pause()
        draft = MapBuilder.build(rooms: rooms, points: detector.accessPoints(), spottedStairs: detector.stairsFootprints())
        unconfirmed = detector.unconfirmedSightings()
        phase = .review
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
