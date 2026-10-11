import ARKit
import AccessCore
import Combine
import UIKit

/// Samples steady camera frames during a scan, asks a vision model for elevators, ramps and stairs, pins
/// each one in 3D using matched-frame depth (raycasts remain a provisional fallback), and checks LiDAR evidence.
///
/// Automatic confirmation requires distinct viewpoints and measured geometry; repeating a model claim
/// never substitutes for missing depth. Copied depth belongs to the exact image sent to the model.
/// Hand-marked pins count right away. Inconclusive finds remain for volunteer review.
@MainActor
final class AccessibilityDetector: ObservableObject {
    /// The frame a detection was found in, for the volunteer to check in review.
    struct Evidence {
        let image: UIImage
        /// Where the model pointed, normalized to the image (0...1, top-left origin).
        let point: CGPoint
    }

    /// Something seen during the scan, in ARKit world coordinates.
    struct Sighting: Identifiable {
        let id = UUID()
        var kind: VisionDetection.Kind
        var name: String
        /// The floor spot: in front of an elevator, the bottom of a ramp, or the bottom step of stairs.
        var position: SIMD3<Float>
        /// Horizontal direction (x, z) away from the viewer when it was seen: into the elevator, up the ramp or stairs.
        var facing: SIMD2<Float>
        var confidence: Float
        var isManual: Bool
        /// Frames that reported it.
        var frames = 1
        /// Independent frames where measured geometry supported the model's claim.
        var verifiedFrames = 0
        /// A bounded window of recent slope measurements; the median is reported.
        var slopes: [Float] = []
        var evidence: Evidence?
        /// Time of the measurement used for position, so backend pose corrections can follow it.
        var measurementTimestamp: TimeInterval?
        var measuredStairs: StairsCheck.Measurement?
        var lastCountedTimestamp: TimeInterval?
        var lastCountedView: SIMD3<Float>?
        var lastCountedDirection: SIMD3<Float>?

        var slopeDegrees: Float? {
            slopes.isEmpty ? nil : slopes.sorted()[slopes.count / 2]
        }

        mutating func addSlope(_ slope: Float) {
            guard slope.isFinite else { return }
            if slopes.count == 64 { slopes.removeFirst() }
            slopes.append(slope)
        }

        var isConfirmed: Bool {
            if isManual { return true }
            // A sign, estimated plane or repeated identical frame cannot confirm an entrance.
            return frames >= 2 && verifiedFrames >= 1
        }

        /// One line for the console.
        var summary: String {
            var line = "\(kind.rawValue) '\(name)': frames \(frames), verified \(verifiedFrames), confidence \(String(format: "%.2f", confidence))"
            if let slope = slopeDegrees { line += String(format: ", slope %.1f°", slope) }
            line += isManual ? ", manual" : ""
            line += isConfirmed ? ", confirmed" : ", unconfirmed"
            line += String(format: ", at (%.1f, %.1f, %.1f)", position.x, position.y, position.z)
            return line
        }
    }

    /// Tallies for the device console, to see why finds do or don't confirm.
    struct Stats {
        var ticks = 0
        var steadyTicks = 0
        var framesSent = 0
        var framesAnalyzed = 0
        var framesFailed = 0
        /// Steady frames that were due but not sent because requests were still in flight.
        var framesDroppedBusy = 0
        var raycastHits = 0
        var raycastMisses = 0
        /// Model detections dropped because no raycast put them on a surface.
        var unplacedDetections = 0
        var stairsVerified = 0
        var stairsRejected = 0
        var stairsInconclusive = 0
        var slopesMeasured = 0
        var slopesUnmeasured = 0
        var totalLatency: TimeInterval = 0

        var summary: String {
            let latency = framesAnalyzed > 0 ? totalLatency / Double(framesAnalyzed) : 0
            return "ticks \(ticks) (steady \(steadyTicks)) · frames sent \(framesSent), analyzed \(framesAnalyzed), failed \(framesFailed), "
                + "dropped while busy \(framesDroppedBusy) · mean latency \(String(format: "%.1f", latency)) s · "
                + "raycasts hit \(raycastHits), missed \(raycastMisses), unplaced detections \(unplacedDetections) · "
                + "stairs verified \(stairsVerified), rejected \(stairsRejected), inconclusive \(stairsInconclusive) · "
                + "slopes measured \(slopesMeasured), unmeasured \(slopesUnmeasured)"
        }
    }

    @Published private(set) var sightings: [Sighting] = []
    private(set) var stats = Stats()
    /// Claims LiDAR showed to be wrong: "stairs" that were flat floor or a wall, "ramps" that were level.
    @Published private(set) var rejectedClaims = 0
    @Published private(set) var framesAnalyzed = 0
    @Published private(set) var lastError: String?
    /// The camera has been moving too much to take a sharp frame for a while.
    @Published private(set) var isWaitingForSteadyCamera = false

    var isEnabled: Bool { client != nil }

    private static let tickInterval: TimeInterval = 0.2
    private static let minimumSampleInterval: TimeInterval = 1.2
    /// One request at a time: a second encode and upload only slows the first, and frames are dropped while busy.
    private static let maxRequestsInFlight = 1
    /// The camera must be this steady for this long before a frame is sent: sharper images, better raycasts.
    private static let maxAngularSpeed: Float = 25 * .pi / 180
    private static let maxLinearSpeed: Float = 0.35
    private static let steadyFor: TimeInterval = 0.3
    private static let minimumConfidence: Float = 0.6
    /// Stairs are a costly false alarm (they block routes), so the model must be surer.
    private static let minimumStairsConfidence: Float = 0.8
    /// Ramps are steeper than about 1:20; anything flatter is just floor. Much steeper is stairs or furniture.
    private static let plausibleRampSlope: ClosedRange<Float> = 1.5...15
    /// Manual/review fallback marker when no visible stair extent was measured: (width, depth).
    static let spottedStairsSize = SIMD2<Float>(1.2, 1.5)
    /// A floor-plane hit further out than this is a grazing ray, not where the model pointed.
    private static let maxFloorPlaneDistance: Float = 6
    /// A horizontal plane this far below the phone is the floor, not a table.
    private static let minimumFloorDrop: Float = 1
    /// Slope samples form a grid this wide around the surface point, in normalized image units.
    /// 4 × 4 = 16 raycasts: enough for SurfaceFit's 8-sample minimum after outliers go, a third of the old 7 × 7.
    private static let slopeSampleSpan: CGFloat = 0.08
    private static let slopeSampleSteps = 4
    /// An independently measured floor, never the model's proposed floor position.
    var floorElevation: ((SIMD3<Float>) -> Float?)?

    private let client = VisionProvider.makeDetector()
    private weak var session: ARSession?
    private var timer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var manualPhotoTask: Task<Void, Never>?
    private var samplingGeneration = 0
    private var isScanning = false
    private var requestsInFlight = 0
    private var sightingIndex = ScanSightingIndex()
    private var sightingOffsets: [UUID: Int] = [:]
    private var lastPose: (transform: simd_float4x4, time: TimeInterval)?
    private var steadySince: TimeInterval?
    private var lastSent: TimeInterval = 0

    func start(session: ARSession) {
        self.session = session
        resume()
    }

    func resume() {
        isScanning = true
        guard timer == nil, isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        let wasRunning = isScanning
        isScanning = false
        samplingGeneration &+= 1
        analysisTask?.cancel()
        analysisTask = nil
        manualPhotoTask?.cancel()
        manualPhotoTask = nil
        requestsInFlight = 0
        timer?.invalidate()
        timer = nil
        lastPose = nil
        steadySince = nil
        isWaitingForSteadyCamera = false
        guard wasRunning else { return }
        Log.detection.notice("paused · \(self.stats.summary, privacy: .public)")
        for sighting in sightings.suffix(16) {
            Log.detection.notice("  \(sighting.summary, privacy: .public)")
        }
    }

    /// Marks whatever is in the center of the screen. The fallback when the model misses something.
    /// For ramps, aim at the middle of the ramp so its slope can be measured; for stairs, at the bottom step.
    func addManual(_ kind: VisionDetection.Kind) {
        guard isScanning, let session, let frame = session.currentFrame else { return }
        let camera = CameraSnapshot(frame.camera, timestamp: frame.timestamp)
        let center = CGPoint(x: 0.5, y: 0.5)
        let slope = kind == .ramp ? measureSlope(around: center, camera: camera, in: session) : nil
        // Rapid taps still create every requested pin, but cannot queue sensor-sized photo copies.
        let snapshot = manualPhotoTask == nil ? FrameEncoder.snapshot(frame.capturedImage) : nil
        let count = sightings.filter { $0.kind == kind }.count
        // The volunteer aimed on purpose, so even without a surface to hit, mark a spot a few meters out.
        let position = locate(center, camera: camera, in: session) ?? {
            let ray = camera.ray(through: center)
            return ray.origin + ray.direction * 3
        }()
        let id = record(
            kind,
            name: "\(kind.title) \(count + 1)",
            at: position,
            seenFrom: camera,
            confidence: 1,
            isManual: true,
            verified: true,
            slope: slope,
            evidence: nil
        )
        guard let snapshot else { return }
        let generation = samplingGeneration
        let encodeTask = Task.detached(priority: .utility) {
            FrameEncoder.portraitJPEG(from: snapshot, maxDimension: FrameEncoder.previewDimension)
        }
        manualPhotoTask = Task { [weak self] in
            defer {
                if self?.samplingGeneration == generation { self?.manualPhotoTask = nil }
            }
            let preview = await withTaskCancellationHandler {
                await encodeTask.value
            } onCancel: {
                encodeTask.cancel()
            }
            guard !Task.isCancelled, self?.samplingGeneration == generation,
                  let preview, let index = self?.sightingOffsets[id] else { return }
            // The volunteer's own photo beats whatever the model's frame showed.
            self?.sightings[index].evidence = Self.evidence(from: preview, point: center)
        }
    }

    func evidence(for id: UUID) -> Evidence? {
        sightingOffsets[id].flatMap { sightings[$0].evidence }
    }

    /// Live tags are local scenery. A large scan keeps all finds for review, while only nearby finds
    /// are considered and at most sixteen tags are projected on each overlay refresh.
    func nearbySightings(to position: SIMD3<Float>) -> [Sighting] {
        sightingIndex.nearby(position, radius: 18, maximumHeightDifference: 4)
            .compactMap { sightingOffsets[$0] }
            .sorted {
                let first = simd_length_squared(sightings[$0].position - position)
                let second = simd_length_squared(sightings[$1].position - position)
                return first == second ? $0 < $1 : first < second
            }
            .prefix(16)
            .map { sightings[$0] }
    }

    func accessPoints() -> [AccessPoint] {
        sightings.filter(\.isConfirmed).compactMap(Self.accessPoint(for:))
    }

    /// Footprints for confirmed stairs, extending from the bottom step up the stairs.
    func stairsFootprints() -> [Footprint] {
        sightings.filter(\.isConfirmed).compactMap(Self.stairsFootprint(for:))
    }

    /// Finds that were placed on a surface and never ruled out, but weren't seen often enough to count.
    /// Review asks the volunteer about each one.
    func unconfirmedSightings() -> [Sighting] {
        sightings.filter { !$0.isConfirmed }
    }

    /// The access point for an elevator or ramp sighting; nil for stairs.
    static func accessPoint(for sighting: Sighting) -> AccessPoint? {
        guard let kind = sighting.kind.accessPointKind else { return nil }
        return AccessPoint(
            id: sighting.id,
            kind: kind,
            name: sighting.name,
            position: sighting.position,
            source: sighting.isManual ? .manual : .detected,
            confidence: sighting.confidence,
            slopeDegrees: sighting.slopeDegrees
        )
    }

    /// The footprint for a stairs sighting, extending from the bottom step up the stairs; nil otherwise.
    static func stairsFootprint(for sighting: Sighting) -> Footprint? {
        guard sighting.kind == .stairs else { return nil }
        if let measured = sighting.measuredStairs?.footprint(id: sighting.id) { return measured }
        // Only explicit manual/review confirmation may use the conservative marker footprint.
        let size = spottedStairsSize
        let bottom = SIMD2(sighting.position.x, sighting.position.z)
        // The footprint's y axis runs up the stairs.
        return Footprint(
            kind: .stairs,
            center: bottom + sighting.facing * size.y / 2,
            size: size,
            yaw: atan2(-sighting.facing.x, sighting.facing.y),
            id: sighting.id
        )
    }

    // MARK: Sampling

    /// Sends a frame when the camera has been steady for a moment and enough time has passed since the last one.
    private func tick() {
        guard isScanning, let session, let frame = session.currentFrame, case .normal = frame.camera.trackingState else { return }
        let now = frame.timestamp
        let pose = frame.camera.transform
        defer { lastPose = (pose, now) }
        guard let last = lastPose, now > last.time else { return }

        let elapsed = Float(now - last.time)
        let turn = simd_quatf(pose) * simd_quatf(last.transform).inverse
        let angle = min(turn.angle, 2 * .pi - turn.angle)
        let isSteady = angle / elapsed < Self.maxAngularSpeed
            && simd_distance(pose.translation, last.transform.translation) / elapsed < Self.maxLinearSpeed
        steadySince = isSteady ? (steadySince ?? now) : nil
        let waiting = now - lastSent > 5 && !isSteady
        if isWaitingForSteadyCamera != waiting { isWaitingForSteadyCamera = waiting }
        stats.ticks += 1
        if isSteady { stats.steadyTicks += 1 }

        guard let steadySince, now - steadySince >= Self.steadyFor,
              now - lastSent >= Self.minimumSampleInterval else { return }
        guard requestsInFlight < Self.maxRequestsInFlight else {
            stats.framesDroppedBusy += 1
            return
        }
        lastSent = now
        analyze(frame)
    }

    /// Copies what's needed out of the frame and lets it go before anything asynchronous starts.
    private func analyze(_ frame: ARFrame) {
        guard let client, let sample = ScanVideoSample.copy(frame) else { return }
        let camera = CameraSnapshot(frame.camera, timestamp: frame.timestamp)
        requestsInFlight += 1
        stats.framesSent += 1
        let number = stats.framesSent
        let generation = samplingGeneration
        // This detached job owns the pixel copy and releases it as soon as encoding ends. The
        // network task below captures only its small JPEG result, never the sensor-sized buffer.
        let encodeTask = Task.detached(priority: .utility) {
            (FrameEncoder.encode(sample.pixels), sample.featureDepth())
        }
        Log.detection.info("frame \(number) sent · steady \(self.stats.steadyTicks)/\(self.stats.ticks) ticks · in flight \(self.requestsInFlight)")
        analysisTask = Task { [weak self] in
            defer {
                if self?.samplingGeneration == generation {
                    self?.requestsInFlight = 0
                    self?.analysisTask = nil
                }
            }
            do {
                let (encoded, depth) = await withTaskCancellationHandler {
                    await encodeTask.value
                } onCancel: {
                    encodeTask.cancel()
                }
                guard let encoded else { return }
                try Task.checkCancellation()
                let started = Date.now
                let detections = try await client.detect(jpeg: encoded.jpeg)
                try Task.checkCancellation()
                guard self?.samplingGeneration == generation else { return }
                await self?.handle(detections, number: number, latency: Date.now.timeIntervalSince(started), camera: camera, depth: depth, preview: encoded.preview, generation: generation)
            } catch {
                guard !Task.isCancelled, self?.samplingGeneration == generation else { return }
                self?.stats.framesFailed += 1
                Log.detection.error("frame \(number) failed: \(error.localizedDescription, privacy: .public)")
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// Places and checks each detection. The raycasts run on the main actor, where ARSession is known to be
    /// safe to call, so the loop yields between detections to keep the UI and ARKit callbacks moving.
    private func handle(_ detections: [VisionDetection], number: Int, latency: TimeInterval, camera: CameraSnapshot, depth: FeatureDepthGeometry?, preview: Data, generation: Int) async {
        guard isScanning, samplingGeneration == generation, !Task.isCancelled else { return }
        framesAnalyzed += 1
        stats.framesAnalyzed += 1
        stats.totalLatency += latency
        lastError = nil
        Log.detection.info("frame \(number) analyzed in \(String(format: "%.1f", latency), privacy: .public) s: \(detections.count) detections")
        // Every find from this frame shares the same JPEG-backed image, rather than retaining one
        // UIImage/JPEG object for every elevator, ramp or staircase returned by the model.
        let evidenceImage = UIImage(data: preview)
        for (index, detection) in detections.prefix(16).enumerated() {
            if index > 0 { await Task.yield() }
            guard isScanning, samplingGeneration == generation, !Task.isCancelled, let session else { return }
            Log.detection.info("  \(detection.kind.rawValue, privacy: .public) '\(detection.name, privacy: .public)' \(String(format: "%.2f", detection.confidence), privacy: .public) at (\(String(format: "%.2f, %.2f", detection.target.x, detection.target.y), privacy: .public))")
            guard detection.isValid, detection.confidence >= Self.minimumConfidence else {
                Log.detection.info("    skipped: below minimum confidence")
                continue
            }
            let target = FrameEncoder.capturedImagePoint(fromPortrait: detection.target)
            let measuredTarget = depth?.target(at: SIMD2(Float(target.x), Float(target.y)))
            guard let position = measuredTarget ?? locate(target, camera: camera, in: session) else {
                // A guessed position would never line up with the next sighting, so it could never confirm.
                stats.unplacedDetections += 1
                Log.detection.info("    dropped: no raycast hit, so it can't be placed")
                continue
            }
            var verified = false
            var slope: Float?
            var stairsMeasurement: StairsCheck.Measurement?
            switch detection.kind {
            case .elevator:
                guard detection.elevatorEvidence != .signOnly, detection.elevatorEvidence != .panelOnly else { continue }
                // A doorway plus a call panel/indicator is stronger semantic evidence than a metal door.
                // The target must also lie on an independently observed floor, not on the door leaf.
                if detection.elevatorEvidence == .doorAndPanel, measuredTarget != nil,
                   let floor = floorElevation?(position), abs(position.y - floor) <= 0.2 {
                    verified = true
                }
            case .ramp:
                slope = await measureSlopeInBatches(around: FrameEncoder.capturedImagePoint(fromPortrait: detection.surface), camera: camera, in: session)
                guard !Task.isCancelled, samplingGeneration == generation else { return }
                if let measured = slope {
                    guard Self.plausibleRampSlope.contains(measured) else {
                        rejectedClaims += 1
                        Log.detection.info("    rejected: slope \(String(format: "%.1f", measured), privacy: .public)° isn't a ramp")
                        continue
                    }
                    verified = true
                }
            case .stairs:
                guard detection.confidence >= Self.minimumStairsConfidence else {
                    Log.detection.info("    skipped: below minimum stairs confidence")
                    continue
                }
                let assessment: StairsCheck.Assessment
                if let depth, let box = detection.bounds {
                    let samples = depth.samples(portraitBox: SIMD4(Float(box.minX), Float(box.minY), Float(box.width), Float(box.height)))
                    assessment = StairsCheck.assess(samples, viewer: camera.transform.translation)
                } else { assessment = StairsCheck.Assessment(verdict: .inconclusive, measurement: nil) }
                stairsMeasurement = assessment.measurement
                switch assessment.verdict {
                case .notStairs:
                    rejectedClaims += 1
                    stats.stairsRejected += 1
                    Log.detection.info("    rejected: LiDAR says not stairs")
                    continue
                case .stairs:
                    verified = measuredTarget != nil && stairsMeasurement?.footprint() != nil
                    stats.stairsVerified += 1
                case .inconclusive:
                    stats.stairsInconclusive += 1
                }
            }
            record(
                detection.kind,
                name: detection.name,
                at: position,
                seenFrom: camera,
                confidence: detection.confidence,
                isManual: false,
                verified: verified,
                slope: slope,
                evidence: evidenceImage.map { Evidence(image: $0, point: detection.target) },
                measuredStairs: stairsMeasurement
            )
        }
    }

    // MARK: Geometry

    /// Casts a ray through a captured-image point onto the scanned surfaces. When the mesh there is still
    /// patchy, the floor planes ARKit has found, extended, catch points on the floor. Nil when nothing does.
    private func locate(_ imagePoint: CGPoint, camera: CameraSnapshot, in session: ARSession) -> SIMD3<Float>? {
        if let position = hit(imagePoint, camera: camera, in: session) {
            Log.detection.info("    placed by raycast at (\(String(format: "%.1f, %.1f, %.1f", position.x, position.y, position.z), privacy: .public))")
            return position
        }
        let ray = camera.ray(through: imagePoint)
        let planes = ARRaycastQuery(origin: ray.origin, direction: ray.direction, allowing: .existingPlaneInfinite, alignment: .horizontal)
        // Extended planes include tables and counters; the floor is the one well below the phone, and a hit
        // far out along the ray is a grazing angle, not where the model pointed.
        let floorHit = session.raycast(planes).map(\.worldTransform.translation).first {
            ray.origin.y - $0.y >= Self.minimumFloorDrop && simd_distance($0, ray.origin) < Self.maxFloorPlaneDistance
        }
        if let position = floorHit {
            Log.detection.info("    placed on a floor plane at (\(String(format: "%.1f, %.1f, %.1f", position.x, position.y, position.z), privacy: .public))")
            return position
        }
        Log.detection.info("    raycast missed, and no floor plane under the ray")
        return nil
    }

    private func hit(_ imagePoint: CGPoint, camera: CameraSnapshot, in session: ARSession) -> SIMD3<Float>? {
        let ray = camera.ray(through: imagePoint)
        let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction, allowing: .estimatedPlane, alignment: .any)
        let position = session.raycast(query).first?.worldTransform.translation
        if position == nil { stats.raycastMisses += 1 } else { stats.raycastHits += 1 }
        return position
    }

    /// Raycasts a small grid around a point on the ramp and fits a plane to the hits.
    private func measureSlope(around center: CGPoint, camera: CameraSnapshot, in session: ARSession) -> Float? {
        finishSlopeMeasurement(slopeSamplePoints(around: center).compactMap { hit($0, camera: camera, in: session) })
    }

    /// Automatic detections yield every four casts, instead of blocking one render frame for the
    /// whole LiDAR verification grid. Manual marks use the same samples and physical checks.
    private func measureSlopeInBatches(around center: CGPoint, camera: CameraSnapshot, in session: ARSession) async -> Float? {
        var samples: [SIMD3<Float>] = []
        for (index, point) in slopeSamplePoints(around: center).enumerated() {
            if index > 0 && index.isMultiple(of: 4) {
                await Task.yield()
                guard !Task.isCancelled else { return nil }
            }
            if let position = hit(point, camera: camera, in: session) { samples.append(position) }
        }
        return finishSlopeMeasurement(samples)
    }

    private func slopeSamplePoints(around center: CGPoint) -> [CGPoint] {
        let steps = Self.slopeSampleSteps
        var points: [CGPoint] = []
        for row in 0..<steps {
            for column in 0..<steps {
                let offset = CGPoint(
                    x: (CGFloat(column) / CGFloat(steps - 1) - 0.5) * Self.slopeSampleSpan,
                    y: (CGFloat(row) / CGFloat(steps - 1) - 0.5) * Self.slopeSampleSpan
                )
                let point = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
                points.append(point)
            }
        }
        return points
    }

    private func finishSlopeMeasurement(_ samples: [SIMD3<Float>]) -> Float? {
        let slope = SurfaceFit.slopeDegrees(of: samples)
        if slope == nil { stats.slopesUnmeasured += 1 } else { stats.slopesMeasured += 1 }
        Log.detection.info("    slope: \(samples.count) of \(Self.slopeSampleSteps * Self.slopeSampleSteps) raycasts hit → \(slope.map { String(format: "%.1f°", $0) } ?? "unmeasured", privacy: .public)")
        return slope
    }

    // MARK: Merging

    /// Sightings of the same kind closer than this are the same thing. Stairs are long, and the model may
    /// point at any of the lower steps, so they merge from further away.
    private static func mergeDistance(for kind: VisionDetection.Kind) -> Float {
        switch kind {
        case .elevator: 0.65
        case .ramp: 2.5
        case .stairs: 3
        }
    }

    /// Adds a sighting, or merges it into a nearby one of the same kind. Returns the sighting's id.
    @discardableResult
    private func record(
        _ kind: VisionDetection.Kind,
        name: String,
        at position: SIMD3<Float>,
        seenFrom camera: CameraSnapshot,
        confidence: Float,
        isManual: Bool,
        verified: Bool,
        slope: Float?,
        evidence: Evidence?,
        measuredStairs: StairsCheck.Measurement? = nil
    ) -> UUID {
        let floor = SIMD2(position.x, position.z)
        let away = floor - SIMD2(camera.transform.translation.x, camera.transform.translation.z)
        let facing = simd_length(away) > 0.1 ? simd_normalize(away) : SIMD2<Float>(0, -1)

        let match = sightingIndex.nearby(position, radius: Self.mergeDistance(for: kind), maximumHeightDifference: 1.5)
            .compactMap { sightingOffsets[$0] }
            .filter { sightings[$0].kind == kind }
            .min {
                simd_distance(sightings[$0].position, position) < simd_distance(sightings[$1].position, position)
            }
        guard let match else {
            var sighting = Sighting(kind: kind, name: name, position: position, facing: facing, confidence: confidence, isManual: isManual)
            sighting.measurementTimestamp = camera.timestamp
            sighting.measuredStairs = measuredStairs
            sighting.lastCountedTimestamp = camera.timestamp
            sighting.lastCountedView = camera.transform.translation
            sighting.lastCountedDirection = -SIMD3(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z)
            sighting.verifiedFrames = verified ? 1 : 0
            if let slope { sighting.addSlope(slope) }
            sighting.evidence = evidence
            sightingOffsets[sighting.id] = sightings.count
            sightings.append(sighting)
            sightingIndex.update(sighting.id, at: sighting.position)
            Log.detection.info("    new sighting · \(sighting.summary, privacy: .public)")
            return sighting.id
        }

        var sighting = sightings[match]
        if isManual {
            // A volunteer's mark beats the model's estimate.
            sighting.position = position
            sighting.measurementTimestamp = camera.timestamp
            sighting.isManual = true
        } else if !sighting.isManual {
            if kind == .stairs {
                // The lowest point seen is the bottom step.
                if position.y < sighting.position.y {
                    sighting.position = position
                    sighting.measurementTimestamp = camera.timestamp
                }
            } else {
                if confidence >= sighting.confidence {
                    sighting.position = position
                    sighting.measurementTimestamp = camera.timestamp
                }
            }
        }
        let blended = sighting.facing * Float(sighting.frames) + facing
        if simd_length(blended) > 1e-3 { sighting.facing = simd_normalize(blended) }
        let direction = -SIMD3(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z)
        if let time = camera.timestamp, let previousTime = sighting.lastCountedTimestamp,
           let previous = sighting.lastCountedView, let previousDirection = sighting.lastCountedDirection,
           FeatureConfirmation.isNewView(position: camera.transform.translation, direction: direction, timestamp: time,
                                         previousPosition: previous, previousDirection: previousDirection, previousTimestamp: previousTime) {
            sighting.frames += 1
            sighting.lastCountedTimestamp = time
            sighting.lastCountedView = camera.transform.translation
            sighting.lastCountedDirection = direction
            if verified { sighting.verifiedFrames += 1 }
        }
        if let measuredStairs, measuredStairs.footprint() != nil,
           sighting.measuredStairs?.footprint() == nil
            || measuredStairs.treadCount >= (sighting.measuredStairs?.treadCount ?? 0) {
            sighting.measuredStairs = measuredStairs
        }
        if let slope { sighting.addSlope(slope) }
        if let evidence, isManual || confidence >= sighting.confidence || sighting.evidence == nil {
            sighting.evidence = evidence
        }
        sighting.confidence = max(sighting.confidence, confidence)
        sightings[match] = sighting
        sightingIndex.update(sighting.id, at: sighting.position)
        Log.detection.info("    merged into sighting · \(sighting.summary, privacy: .public)")
        return sighting.id
    }

    /// `UIImage(data:)` decodes lazily, so each sighting holds only the small JPEG until review shows it.
    private static func evidence(from preview: Data, point: CGPoint) -> Evidence? {
        UIImage(data: preview).map { Evidence(image: $0, point: point) }
    }
}

/// The camera pose and intrinsics of one frame, kept so a ray can be cast after the model replies
/// without holding on to the ARFrame itself.
struct CameraSnapshot {
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize
    let timestamp: TimeInterval?

    init(_ camera: ARCamera, timestamp: TimeInterval? = nil) {
        transform = camera.transform
        intrinsics = camera.intrinsics
        imageResolution = camera.imageResolution
        self.timestamp = timestamp
    }

    /// World-space ray through a normalized point of the captured image.
    func ray(through point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let px = Float(point.x * imageResolution.width), py = Float(point.y * imageResolution.height)
        let fx = intrinsics[0][0], fy = intrinsics[1][1], cx = intrinsics[2][0], cy = intrinsics[2][1]
        // Camera space looks down -z with +y up; image rows grow downward.
        let local = SIMD4<Float>((px - cx) / fx, -(py - cy) / fy, -1, 0)
        let world = transform * local
        return (transform.translation, simd_normalize(SIMD3(world.x, world.y, world.z)))
    }
}

private extension ScanVideoSample {
    /// Decoded off the main actor; the network request retains only this small calibrated depth,
    /// JPEG bytes and the original pose, never an ARFrame or sensor-sized image buffer.
    func featureDepth() -> FeatureDepthGeometry? {
        guard let depth, let confidence, let stride = confidenceBytesPerRow,
              depthWidth > 0, depthHeight > 0 else { return nil }
        var values: [Float?] = []
        var quality: [Int] = []
        depth.withUnsafeBytes { bytes in
            confidence.withUnsafeBytes { confidenceBytes in
                for row in 0..<depthHeight { for column in 0..<depthWidth {
                    let value = bytes.loadUnaligned(fromByteOffset: row * depthBytesPerRow + column * 4, as: Float.self)
                    values.append(value.isFinite && value > 0 ? value : nil)
                    quality.append(Int(confidenceBytes.load(fromByteOffset: row * stride + column, as: UInt8.self)))
                } }
            }
        }
        return FeatureDepthGeometry(CaptureDepthFrame(id: "detection", timestampSeconds: timestamp,
            mapFromCamera: mapFromCamera, camera: camera,
            depth: CaptureDepthImage(width: depthWidth, height: depthHeight, valuesM: values, confidence: quality)))
    }
}
