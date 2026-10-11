import ARKit
import AccessCore
import Combine
import Foundation
import Vision

/// Reads the sign the camera is pointed at, live: room plates, exits, restrooms, lobbies.
///
/// A few times a second it copies one AR frame, runs Apple Vision OCR on the middle of the view,
/// groups lines into sign plates, and measures the plate with the frame's own LiDAR depth, so every
/// sign has a metric position in the session's map frame. The same reading twice in a row, in the
/// same place, locks it; a vision model can then check it. Work stays bounded: one frame in flight,
/// nothing retained from ARKit's buffer pool.
@MainActor
final class SignReader: ObservableObject {
    /// One sign being read, refined as the camera keeps seeing it.
    struct Sighting: Identifiable, Equatable {
        enum Check: Equatable {
            case none
            case checking
            case confirmed
            case corrected(from: String)
            case failed
        }

        let id = UUID()
        var reading: SignReading
        var text: String
        /// The sign's center in map meters.
        var position: SIMD3<Float>
        /// Where the camera was, which tells the corridor side of a door from the room side.
        var viewer: SIMD3<Float>
        /// The plate on screen, normalized in the upright image (top-left origin), from the latest read.
        var box: CGRect
        var hits: Int
        var lastSeen: Date
        var crop: Data?
        var check = Check.none
    }

    @Published private(set) var focus: Sighting?
    @Published private(set) var isLocked = false
    @Published private(set) var isRunning = false
    /// Guidance when text is visible but can't be used yet, e.g. too far for depth.
    @Published private(set) var hint: String?
    @Published private(set) var isAskingAI = false

    var canAskAI: Bool { ai != nil }

    private let session: ARSession
    private let ai = SignAIClient()
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0
    private var lastResult = Date.distantPast

    private static let interval: TimeInterval = 0.35
    private static let locksAfter = 2
    private static let sameSign: Float = 0.75
    /// A lock survives brief glances away, so the card doesn't flicker while someone taps it.
    private static let lockHold: TimeInterval = 4
    private static let focusHold: TimeInterval = 1.5

    init(session: ARSession) {
        self.session = session
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        isRunning = false
        generation += 1
        timer?.invalidate()
        timer = nil
        inFlight = false
        reset()
    }

    /// Forgets the current sign and looks for the next one.
    func reset() {
        focus = nil
        isLocked = false
        hint = nil
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator fixtures show a locked sign without a camera.
    func preview(_ sighting: Sighting) {
        focus = sighting
        isLocked = true
    }
    #endif

    // MARK: Reading

    private func tick() {
        if let focus, Date.now.timeIntervalSince(focus.lastSeen) > (isLocked ? Self.lockHold : Self.focusHold) {
            if !isLocked || focus.check != .checking { reset() }
        }
        if Date.now.timeIntervalSince(lastResult) > 2 { hint = nil }
        guard isRunning, !inFlight, !isAskingAI, let input = Self.copy(session.currentFrame) else { return }
        inFlight = true
        let request = generation
        Task.detached(priority: .userInitiated) {
            let plate = Self.read(input)
            await MainActor.run { [weak self] in
                guard let self, self.generation == request else { return }
                self.inFlight = false
                self.apply(plate, viewer: input.viewer)
            }
        }
    }

    private func apply(_ plate: Plate?, viewer: SIMD3<Float>) {
        guard let plate else { return }
        lastResult = .now
        guard let position = plate.position else {
            hint = "Move a little closer to “\(plate.reading.title)”"
            return
        }
        hint = nil
        if var current = focus, current.reading.title == plate.reading.title || current.reading.roomNumber.map({ $0 == plate.reading.roomNumber }) == true,
           simd_distance(current.position, position) < Self.sameSign {
            current.hits += 1
            // Running average: each read refines the measured position.
            let weight = 1 / Float(min(current.hits, 6))
            current.position += (position - current.position) * weight
            current.viewer = viewer
            current.box = plate.box
            current.lastSeen = .now
            if plate.crop != nil { current.crop = plate.crop }
            // A longer plate (number plus name) is the better reading of the same sign, unless AI already spoke.
            if case .none = current.check, plate.text.count > current.text.count {
                current.reading = plate.reading; current.text = plate.text
            }
            focus = current
            if !isLocked, current.hits >= Self.locksAfter { lock() }
        } else if !isLocked {
            focus = Sighting(reading: plate.reading, text: plate.text, position: position, viewer: viewer,
                             box: plate.box, hits: 1, lastSeen: .now, crop: plate.crop)
        }
    }

    private func lock() {
        isLocked = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        check()
    }

    /// Asks the vision model to confirm or correct the locked sign. The OCR reading stands meanwhile.
    private func check() {
        guard let ai, let sighting = focus, let crop = sighting.crop else { return }
        focus?.check = .checking
        let id = sighting.id
        Task {
            let reading = try? await ai.read(jpeg: crop, ocrText: sighting.text)
            guard focus?.id == id else { return }
            // No answer, or the model doesn't think it's a place sign: the OCR reading stands.
            guard let reading else { focus?.check = .failed; return }
            let before = focus?.reading.fullTitle ?? ""
            focus?.reading.category = reading.category
            focus?.reading.title = reading.title
            focus?.reading.detail = reading.detail ?? focus?.reading.detail
            focus?.reading.roomNumber = reading.roomNumber ?? focus?.reading.roomNumber
            let after = focus?.reading.fullTitle ?? ""
            focus?.check = before.caseInsensitiveCompare(after) == .orderedSame ? .confirmed : .corrected(from: before)
        }
    }

    /// For signs OCR can't read (pictograms): sends the middle of the view to the vision model, and
    /// measures the wall there with LiDAR.
    func askAI() {
        guard let ai, !isAskingAI, let input = Self.copy(session.currentFrame) else { return }
        isAskingAI = true
        let request = generation
        Task {
            defer { if generation == request { isAskingAI = false } }
            let center = CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4)
            let prepared = await Task.detached(priority: .userInitiated) { () -> (Data?, SIMD3<Float>?) in
                let jpeg = FrameEncoder.portraitJPEG(from: input.snapshot, box: center, maxDimension: 768)
                let probe = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
                let sensor = CaptureImageOrientation.sensorBox(fromUpright: [probe.minX, probe.minY, probe.width, probe.height])
                return (jpeg, input.depthFrame().flatMap { SignLocalizer.measure(boxSensorNorm: sensor, in: $0)?.position })
            }.value
            guard generation == request, let jpeg = prepared.0 else { return }
            guard let position = prepared.1 else { hint = "Move closer so the sign is within a few meters"; return }
            guard let reading = try? await ai.read(jpeg: jpeg, ocrText: nil), generation == request else {
                hint = "AI couldn’t find a place sign there"
                return
            }
            focus = Sighting(reading: reading, text: reading.fullTitle, position: position, viewer: input.viewer,
                             box: center, hits: Self.locksAfter, lastSeen: .now, crop: jpeg, check: .confirmed)
            isLocked = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    // MARK: Frame work (off the main thread)

    /// Everything one read needs, copied out of the AR frame so ARKit can recycle it.
    private struct Input: @unchecked Sendable {
        let snapshot: FrameEncoder.Snapshot
        let depth: Data
        let depthWidth: Int
        let depthHeight: Int
        let depthStride: Int
        let confidence: Data?
        let confidenceStride: Int
        let camera: CaptureCameraCalibration
        let mapFromCamera: [Float]
        let timestamp: TimeInterval
        let viewer: SIMD3<Float>

        nonisolated func depthFrame() -> CaptureDepthFrame? {
            var values: [Float?] = []
            values.reserveCapacity(depthWidth * depthHeight)
            depth.withUnsafeBytes { bytes in
                for row in 0..<depthHeight {
                    for column in 0..<depthWidth {
                        let value = bytes.loadUnaligned(fromByteOffset: row * depthStride + column * 4, as: Float.self)
                        values.append(value.isFinite && value > 0 ? value : nil)
                    }
                }
            }
            let levels: [Int]? = confidence.map { data in
                data.withUnsafeBytes { bytes in
                    (0..<depthHeight).flatMap { row in
                        (0..<depthWidth).map { Int(bytes.load(fromByteOffset: row * confidenceStride + $0, as: UInt8.self)) }
                    }
                }
            }
            return CaptureDepthFrame(id: "live", timestampSeconds: timestamp, mapFromCamera: mapFromCamera, camera: camera,
                                     depth: CaptureDepthImage(width: depthWidth, height: depthHeight, valuesM: values, confidence: levels))
        }
    }

    struct Plate: Sendable {
        var reading: SignReading
        var text: String
        var box: CGRect
        var position: SIMD3<Float>?
        var crop: Data?
    }

    private static func copy(_ frame: ARFrame?) -> Input? {
        guard let frame, case .normal = frame.camera.trackingState,
              let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let snapshot = FrameEncoder.snapshot(frame.capturedImage) else { return nil }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              let depth = bytes(of: depthMap) else { return nil }
        let confidence = sceneDepth.confidenceMap.flatMap { map in
            CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent8 ? bytes(of: map) : nil
        }
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        return Input(
            snapshot: snapshot, depth: depth,
            depthWidth: CVPixelBufferGetWidth(depthMap), depthHeight: CVPixelBufferGetHeight(depthMap),
            depthStride: CVPixelBufferGetBytesPerRow(depthMap),
            confidence: confidence, confidenceStride: sceneDepth.confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0,
            camera: CaptureCameraCalibration(imageWidth: Int(frame.camera.imageResolution.width),
                                             imageHeight: Int(frame.camera.imageResolution.height),
                                             fx: intrinsics[0][0], fy: intrinsics[1][1], cx: intrinsics[2][0], cy: intrinsics[2][1]),
            mapFromCamera: ScanExporter.matrix(transform), timestamp: frame.timestamp,
            viewer: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z))
    }

    private static func bytes(of buffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return Data(bytes: base, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    /// OCR on the middle of the upright frame, lines grouped into plates, the most central readable
    /// plate measured with depth.
    private nonisolated static func read(_ input: Input) -> Plate? {
        read(handler: FrameEncoder.uprightRequestHandler(for: input.snapshot), depthFrame: input.depthFrame) { box in
            FrameEncoder.portraitJPEG(from: input.snapshot, box: box, maxDimension: 640)
        }
    }

    /// The reading core, independent of ARKit: any upright image handler, its matched depth, and a cropper.
    nonisolated static func read(handler: VNImageRequestHandler, depthFrame: () -> CaptureDepthFrame?,
                                 crop: (CGRect) -> Data?) -> Plate? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Room identifiers must not be autocorrected into words.
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.018
        // Vision's region is bottom-left origin in the upright image: the middle of the view.
        request.regionOfInterest = CGRect(x: 0.06, y: 0.12, width: 0.88, height: 0.76)
        do {
            try handler.perform([request])
        } catch { return nil }
        let lines: [(text: String, box: CGRect)] = (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
            // Boxes are relative to the region; map back to the whole upright image, top-left origin.
            let region = request.regionOfInterest, box = result.boundingBox
            let x = region.minX + box.minX * region.width
            let y = region.minY + box.minY * region.height
            let full = CGRect(x: x, y: 1 - (y + box.height * region.height),
                              width: box.width * region.width, height: box.height * region.height)
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (text, full)
        }
        let plates = group(lines).compactMap { group -> Plate? in
            let ordered = group.sorted { $0.box.minY < $1.box.minY }
            guard let reading = SignInterpreter.interpret(ordered.map(\.text)) else { return nil }
            let box = ordered.map(\.box).reduce(ordered[0].box) { $0.union($1) }
            return Plate(reading: reading, text: ordered.map(\.text).joined(separator: " "), box: box)
        }
        let center = CGPoint(x: 0.5, y: 0.5)
        guard var plate = plates.min(by: { distance($0.box, center) < distance($1.box, center) }) else { return nil }
        guard let frame = depthFrame() else { return plate }
        // Measure the whole plate, else its largest line: thin text can miss the depth grid.
        let sensor = { (box: CGRect) in CaptureImageOrientation.sensorBox(fromUpright: [box.minX, box.minY, box.width, box.height]) }
        plate.position = SignLocalizer.measure(boxSensorNorm: sensor(plate.box), in: frame)?.position
            ?? SignLocalizer.measure(boxSensorNorm: sensor(plate.box.insetBy(dx: -plate.box.width * 0.15, dy: -plate.box.height * 0.3)), in: frame)?.position
        if plate.position != nil {
            let padded = plate.box.insetBy(dx: -max(0.04, plate.box.width * 0.35), dy: -max(0.04, plate.box.height * 0.6))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            plate.crop = crop(padded)
        }
        return plate
    }

    /// Lines stacked on one plate: overlapping horizontally and close vertically.
    private nonisolated static func group(_ lines: [(text: String, box: CGRect)]) -> [[(text: String, box: CGRect)]] {
        var groups: [[(text: String, box: CGRect)]] = []
        for line in lines.sorted(by: { $0.box.minY < $1.box.minY }) {
            if let index = groups.firstIndex(where: { group in
                group.contains { other in
                    let gap = max(line.box.minY - other.box.maxY, other.box.minY - line.box.maxY)
                    let overlaps = line.box.minX < other.box.maxX && other.box.minX < line.box.maxX
                    return overlaps && gap < 1.3 * max(line.box.height, other.box.height)
                }
            }) {
                groups[index].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups
    }

    private nonisolated static func distance(_ box: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(box.midX - point.x, box.midY - point.y)
    }
}
