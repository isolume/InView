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
    /// The volunteer just walked through a doorway: RoomPlan keeps one room per section, so suggest a new one.
    @Published private(set) var suggestsNewSection = false

    let session = ARSession()
    let detector = AccessibilityDetector()

    private(set) lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: session)
        view.delegate = captureDelegate
        // Live updates too, as Apple's RoomPlan sample does alongside the view's own delegate.
        view.captureSession.delegate = sessionDelegate
        return view
    }()

    private lazy var captureDelegate = CaptureViewDelegate(
        onError: { [weak self] error in self?.errorMessage = error.localizedDescription },
        onRoom: { [weak self] room in self?.sectionProcessed(room) }
    )
    private lazy var sessionDelegate = CaptureSessionDelegate(
        onUpdate: { [weak self] room in self?.liveRoomUpdated(room) },
        onEnd: { [weak self] error in self?.sessionEnded(error) }
    )
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
    private var finishAfterProcessing = false
    private var reportTask: Task<Void, Never>?

    init() {
        phase = RoomCaptureSession.isSupported ? .scanning : .unsupported
    }

    func start() {
        guard phase == .scanning, !hasStarted else { return }
        hasStarted = true
        beginSection()
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

    func dismissSectionSuggestion() {
        suggestsNewSection = false
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
        doorMonitor?.invalidate()
        doorMonitor = nil
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

    /// Writes the map; the world map archive runs off the main thread.
    func save() async throws {
        guard let draft, let worldMap else { return }
        let report = report ?? AccessibilityReport(map: draft)
        try await MapStore.save(draft, report: report, rooms: rooms, worldMap: worldMap, startView: startView)
    }

    private func endSection(thenFinish finish: Bool) {
        guard phase == .scanning else { return }
        finishAfterProcessing = finish
        phase = .processing
        detector.pause()
        doorMonitor?.invalidate()
        doorMonitor = nil
        suggestsNewSection = false
        // Keep the AR session running so the next section and the world map share its coordinates.
        captureView.captureSession.stop(pauseARSession: false)
    }

    /// Runs a RoomPlan capture for a new section and resets what's remembered about the live room.
    private func beginSection() {
        memory = RoomMemory()
        liveDoors = []
        doorSides = [:]
        sectionStarted = .now
        suggestsNewSection = false
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        doorMonitor = Timer.scheduledTimer(withTimeInterval: Self.doorMonitorInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDoorways() }
        }
    }

    private func liveRoomUpdated(_ room: CapturedRoom) {
        guard phase == .scanning else { return }
        memory.remember(room)
        liveDoors = room.doors
    }

    private func sessionEnded(_ error: Error?) {
        if let error {
            Log.scan.error("RoomPlan session ended with error: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        } else {
            Log.scan.notice("RoomPlan session ended")
        }
    }

    /// Remembers what RoomPlan saw live that its processed room left out, so the map keeps it.
    private func recoverDroppedParts(from room: CapturedRoom) {
        let missing = memory.missing(from: room)
        Log.scan.notice("section \(self.rooms.count): RoomPlan kept \(RoomParts(room).count) of \(self.memory.count) live items; recovering \(missing.count)")
        if !missing.isEmpty { recovered.append(missing) }
    }

    /// Notices the camera passing through a doorway RoomPlan has found, and suggests a new section once.
    private func checkDoorways() {
        guard phase == .scanning, !suggestsNewSection, let frame = session.currentFrame else { return }
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
        switch phase {
        case .processing:
            rooms.append(room)
            sectionCount = rooms.count
            Log.scan.notice("section \(self.rooms.count) processed: \(room.walls.count) walls, \(room.doors.count) doors, \(room.objects.count) objects")
            recoverDroppedParts(from: room)
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
            doorMonitor?.invalidate()
            doorMonitor = nil
            suggestsNewSection = false
            Log.scan.error("RoomPlan ended section \(self.rooms.count) on its own: \(self.errorMessage ?? "no error reported", privacy: .public)")
            recoverDroppedParts(from: room)
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
        beginSection()
        detector.resume()
    }

    private func worldMapCaptured(_ worldMap: ARWorldMap?, error: Error?) {
        guard phase == .savingWorldMap else { return }
        guard let worldMap else {
            errorMessage = "Couldn't capture the AR map (\(error?.localizedDescription ?? "unknown error")). Move the phone slowly around the area and try again."
            return
        }
        self.worldMap = worldMap
        session.pause()
        draft = MapBuilder.build(rooms: rooms, recovered: recovered, points: detector.accessPoints(), spottedStairs: detector.stairsFootprints())
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
    private let onEnd: @MainActor (Error?) -> Void

    init(onUpdate: @escaping @MainActor (CapturedRoom) -> Void, onEnd: @escaping @MainActor (Error?) -> Void) {
        self.onUpdate = onUpdate
        self.onEnd = onEnd
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor in onUpdate(room) }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        Task { @MainActor in onEnd(error) }
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
