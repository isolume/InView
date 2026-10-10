import ARKit
import AccessCore
import Combine
import RealityKit
import RoomPlan
import SwiftUI

/// Drives a volunteer scan: RoomPlan capture of one or more sections with live vision detection,
/// then a check-in at the printed marker that ties everything to the venue frame.
@MainActor
final class ScanController: ObservableObject {
    enum Phase: Equatable {
        case unsupported
        case scanning
        case processing
        case checkIn
        case review
    }

    @Published private(set) var phase: Phase
    @Published private(set) var sectionCount = 0
    @Published private(set) var markerProgress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var draft: VenueMap?

    let session = ARSession()
    let detector = AccessibilityDetector()

    private(set) lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: session)
        view.delegate = captureDelegate
        return view
    }()

    private(set) lazy var checkInView: ARView = {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }()

    private lazy var captureDelegate = CaptureViewDelegate(
        onError: { [weak self] error in self?.errorMessage = error.localizedDescription },
        onRoom: { [weak self] room in self?.sectionProcessed(room) }
    )
    private var rooms: [CapturedRoom] = []
    private var hasStarted = false
    private var finishAfterProcessing = false
    private var markerSampler = MarkerSampler()
    private var markerTimer: Timer?

    init() {
        phase = RoomCaptureSession.isSupported ? .scanning : .unsupported
    }

    func start() {
        guard phase == .scanning, !hasStarted else { return }
        hasStarted = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        detector.start(session: session)
    }

    /// Ends the current section and starts another in the same coordinate space, for floors too big for one scan.
    func addSection() { endSection(thenFinish: false) }

    func finish() { endSection(thenFinish: true) }

    func stop() {
        markerTimer?.invalidate()
        markerTimer = nil
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

    func save() throws {
        guard let draft else { return }
        try MapStore.save(draft, rooms: rooms)
    }

    private func endSection(thenFinish finish: Bool) {
        guard phase == .scanning else { return }
        finishAfterProcessing = finish
        phase = .processing
        detector.pause()
        // Keep the AR session running so the next section, and the marker, share its world frame.
        captureView.captureSession.stop(pauseARSession: false)
    }

    private func sectionProcessed(_ room: CapturedRoom) {
        guard phase == .processing else { return }
        rooms.append(room)
        sectionCount = rooms.count
        if finishAfterProcessing {
            beginCheckIn()
        } else {
            phase = .scanning
            captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
            detector.resume()
        }
    }

    private func beginCheckIn() {
        guard let marker = Marker.referenceImage else {
            errorMessage = "The check-in marker image is missing from the app."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.detectionImages = [marker]
        configuration.maximumNumberOfTrackedImages = 1
        // No reset options: the world frame RoomPlan used survives, so walls, pins and the marker line up.
        session.run(configuration)
        phase = .checkIn
        markerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMarker() }
        }
    }

    private func sampleMarker() {
        guard let frame = session.currentFrame else { return }
        markerSampler.add(frame)
        markerProgress = markerSampler.progress
        guard let venue = markerSampler.venueFrame else { return }
        markerTimer?.invalidate()
        markerTimer = nil
        session.pause()
        draft = MapBuilder.build(rooms: rooms, points: detector.accessPoints(in: venue), venue: venue)
        phase = .review
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
