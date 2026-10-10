import ARKit
import AccessCore
import Combine
import UIKit

/// Samples steady camera frames during a scan, asks a vision model for elevators, ramps and stairs, pins
/// each one in 3D by casting rays onto the scanned surfaces, and checks the model's claims against LiDAR.
///
/// A detection only counts once it's been seen in more than one frame, and ramps and stairs also need
/// LiDAR to agree at least once (or many more sightings when LiDAR can't tell). Hand-marked pins count right away.
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
        /// Frames where LiDAR agreed with the model (ramps and stairs only).
        var verifiedFrames = 0
        /// Every slope measurement so far; the median is reported.
        var slopes: [Float] = []
        var evidence: Evidence?

        var slopeDegrees: Float? {
            slopes.isEmpty ? nil : slopes.sorted()[slopes.count / 2]
        }

        var isConfirmed: Bool {
            if isManual { return true }
            switch kind {
            case .elevator: return frames >= 2
            case .ramp, .stairs: return frames >= 2 && (verifiedFrames >= 1 || frames >= 4)
            }
        }
    }

    @Published private(set) var sightings: [Sighting] = []
    /// Claims LiDAR showed to be wrong: "stairs" that were flat floor or a wall, "ramps" that were level.
    @Published private(set) var rejectedClaims = 0
    @Published private(set) var framesAnalyzed = 0
    @Published private(set) var lastError: String?
    /// The camera has been moving too much to take a sharp frame for a while.
    @Published private(set) var isWaitingForSteadyCamera = false

    var isEnabled: Bool { client != nil }

    private static let tickInterval: TimeInterval = 0.2
    private static let minimumSampleInterval: TimeInterval = 1.2
    private static let maxRequestsInFlight = 3
    /// The camera must be this steady for this long before a frame is sent: sharper images, better raycasts.
    private static let maxAngularSpeed: Float = 25 * .pi / 180
    private static let maxLinearSpeed: Float = 0.35
    private static let steadyFor: TimeInterval = 0.3
    private static let minimumConfidence: Float = 0.6
    /// Stairs are a costly false alarm (they block routes), so the model must be surer.
    private static let minimumStairsConfidence: Float = 0.8
    /// Ramps are steeper than about 1:20; anything flatter is just floor. Much steeper is stairs or furniture.
    private static let plausibleRampSlope: ClosedRange<Float> = 1.5...15
    /// Stairs the camera spots are drawn this size, starting at the bottom step: (width, depth).
    static let spottedStairsSize = SIMD2<Float>(1.2, 1.5)
    /// Slope samples form a grid this wide around the surface point, in normalized image units.
    private static let slopeSampleSpan: CGFloat = 0.08
    private static let slopeSampleSteps = 7

    private let client = VisionProvider.makeDetector()
    private weak var session: ARSession?
    private var timer: Timer?
    private var requestsInFlight = 0
    private var lastPose: (transform: simd_float4x4, time: TimeInterval)?
    private var steadySince: TimeInterval?
    private var lastSent: TimeInterval = 0

    func start(session: ARSession) {
        self.session = session
        resume()
    }

    func resume() {
        guard timer == nil, isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        lastPose = nil
        steadySince = nil
        isWaitingForSteadyCamera = false
    }

    /// Marks whatever is in the center of the screen. The fallback when the model misses something.
    /// For ramps, aim at the middle of the ramp so its slope can be measured; for stairs, at the bottom step.
    func addManual(_ kind: VisionDetection.Kind) {
        guard let session, let frame = session.currentFrame else { return }
        let camera = CameraSnapshot(frame.camera)
        let center = CGPoint(x: 0.5, y: 0.5)
        let slope = kind == .ramp ? measureSlope(around: center, camera: camera, in: session) : nil
        let photo = FrameEncoder.portraitJPEG(from: frame.capturedImage).flatMap { Self.evidence(from: $0, point: center) }
        let count = sightings.filter { $0.kind == kind }.count
        record(
            kind,
            name: "\(kind.title) \(count + 1)",
            at: locate(center, camera: camera, in: session),
            seenFrom: camera,
            confidence: 1,
            isManual: true,
            verified: true,
            slope: slope,
            evidence: photo
        )
    }

    func evidence(for id: UUID) -> Evidence? {
        sightings.first { $0.id == id }?.evidence
    }

    func accessPoints() -> [AccessPoint] {
        sightings.filter(\.isConfirmed).compactMap { sighting in
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
    }

    /// Footprints for confirmed stairs, extending from the bottom step up the stairs.
    func stairsFootprints() -> [Footprint] {
        sightings.filter { $0.kind == .stairs && $0.isConfirmed }.map { sighting in
            let size = Self.spottedStairsSize
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
    }

    // MARK: Sampling

    /// Sends a frame when the camera has been steady for a moment and enough time has passed since the last one.
    private func tick() {
        guard let session, let frame = session.currentFrame, case .normal = frame.camera.trackingState else { return }
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
        isWaitingForSteadyCamera = now - lastSent > 5 && !isSteady

        guard let steadySince, now - steadySince >= Self.steadyFor,
              now - lastSent >= Self.minimumSampleInterval,
              requestsInFlight < Self.maxRequestsInFlight else { return }
        lastSent = now
        analyze(frame)
    }

    private func analyze(_ frame: ARFrame) {
        guard let client else { return }
        let camera = CameraSnapshot(frame.camera)
        let pixelBuffer = frame.capturedImage
        requestsInFlight += 1
        Task { [weak self] in
            defer { self?.requestsInFlight -= 1 }
            do {
                let encode = Task.detached(priority: .utility) { FrameEncoder.portraitJPEG(from: pixelBuffer, maxDimension: 1536) }
                guard let jpeg = await encode.value else { return }
                let detections = try await client.detect(jpeg: jpeg)
                self?.handle(detections, camera: camera, jpeg: jpeg)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func handle(_ detections: [VisionDetection], camera: CameraSnapshot, jpeg: Data) {
        framesAnalyzed += 1
        lastError = nil
        guard let session else { return }
        for detection in detections where detection.confidence >= Self.minimumConfidence {
            let target = FrameEncoder.capturedImagePoint(fromPortrait: detection.target)
            let position = locate(target, camera: camera, in: session)
            var verified = false
            var slope: Float?
            switch detection.kind {
            case .elevator:
                break
            case .ramp:
                slope = measureSlope(around: FrameEncoder.capturedImagePoint(fromPortrait: detection.surface), camera: camera, in: session)
                if let measured = slope {
                    guard Self.plausibleRampSlope.contains(measured) else {
                        rejectedClaims += 1
                        continue
                    }
                    verified = true
                }
            case .stairs:
                guard detection.confidence >= Self.minimumStairsConfidence else { continue }
                switch checkStairs(around: detection.target, camera: camera, in: session) {
                case .notStairs:
                    rejectedClaims += 1
                    continue
                case .stairs:
                    verified = true
                case .inconclusive:
                    break
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
                evidence: Self.evidence(from: jpeg, point: detection.target)
            )
        }
    }

    // MARK: Geometry

    /// Raycasts a strip of the image around the claimed stairs, above and below the bottom step so stairs
    /// going up or down are both covered, and asks whether the surface there climbs like stairs.
    private func checkStairs(around portraitPoint: CGPoint, camera: CameraSnapshot, in session: ARSession) -> StairsCheck.Verdict {
        var samples: [SIMD3<Float>] = []
        for column in [-0.03, 0, 0.03] {
            for row in stride(from: 0.12, through: -0.24, by: -0.03) {
                let point = CGPoint(x: min(1, max(0, portraitPoint.x + column)), y: min(1, max(0, portraitPoint.y + row)))
                if let hit = hit(FrameEncoder.capturedImagePoint(fromPortrait: point), camera: camera, in: session) {
                    samples.append(hit)
                }
            }
        }
        return StairsCheck.classify(samples, viewer: camera.transform.translation)
    }

    /// Casts a ray through a captured-image point onto the scanned surfaces, falling back to a point a few meters out.
    private func locate(_ imagePoint: CGPoint, camera: CameraSnapshot, in session: ARSession) -> SIMD3<Float> {
        hit(imagePoint, camera: camera, in: session) ?? {
            let ray = camera.ray(through: imagePoint)
            return ray.origin + ray.direction * 3
        }()
    }

    private func hit(_ imagePoint: CGPoint, camera: CameraSnapshot, in session: ARSession) -> SIMD3<Float>? {
        let ray = camera.ray(through: imagePoint)
        let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction, allowing: .estimatedPlane, alignment: .any)
        return session.raycast(query).first?.worldTransform.translation
    }

    /// Raycasts a small grid around a point on the ramp and fits a plane to the hits.
    private func measureSlope(around center: CGPoint, camera: CameraSnapshot, in session: ARSession) -> Float? {
        let steps = Self.slopeSampleSteps
        var samples: [SIMD3<Float>] = []
        for row in 0..<steps {
            for column in 0..<steps {
                let offset = CGPoint(
                    x: (CGFloat(column) / CGFloat(steps - 1) - 0.5) * Self.slopeSampleSpan,
                    y: (CGFloat(row) / CGFloat(steps - 1) - 0.5) * Self.slopeSampleSpan
                )
                let point = CGPoint(x: center.x + offset.x, y: center.y + offset.y)
                if let position = hit(point, camera: camera, in: session) { samples.append(position) }
            }
        }
        return SurfaceFit.slopeDegrees(of: samples)
    }

    // MARK: Merging

    /// Sightings of the same kind closer than this are the same thing. Stairs are long, and the model may
    /// point at any of the lower steps, so they merge from further away.
    private static func mergeDistance(for kind: VisionDetection.Kind) -> Float {
        switch kind {
        case .elevator: 2
        case .ramp: 2.5
        case .stairs: 3
        }
    }

    private func record(
        _ kind: VisionDetection.Kind,
        name: String,
        at position: SIMD3<Float>,
        seenFrom camera: CameraSnapshot,
        confidence: Float,
        isManual: Bool,
        verified: Bool,
        slope: Float?,
        evidence: Evidence?
    ) {
        let floor = SIMD2(position.x, position.z)
        let away = floor - SIMD2(camera.transform.translation.x, camera.transform.translation.z)
        let facing = simd_length(away) > 0.1 ? simd_normalize(away) : SIMD2<Float>(0, -1)

        let match = sightings.firstIndex {
            $0.kind == kind && simd_distance(SIMD2($0.position.x, $0.position.z), floor) < Self.mergeDistance(for: kind)
        }
        guard let match else {
            var sighting = Sighting(kind: kind, name: name, position: position, facing: facing, confidence: confidence, isManual: isManual)
            sighting.verifiedFrames = verified ? 1 : 0
            if let slope { sighting.slopes.append(slope) }
            sighting.evidence = evidence
            sightings.append(sighting)
            return
        }

        var sighting = sightings[match]
        if isManual {
            // A volunteer's mark beats the model's estimate.
            sighting.position = position
            sighting.isManual = true
        } else if !sighting.isManual {
            if kind == .stairs {
                // The lowest point seen is the bottom step.
                if position.y < sighting.position.y { sighting.position = position }
            } else {
                sighting.position += (position - sighting.position) / Float(sighting.frames + 1)
            }
        }
        let blended = sighting.facing * Float(sighting.frames) + facing
        if simd_length(blended) > 1e-3 { sighting.facing = simd_normalize(blended) }
        sighting.frames += 1
        if verified { sighting.verifiedFrames += 1 }
        if let slope { sighting.slopes.append(slope) }
        if let evidence, isManual || confidence >= sighting.confidence || sighting.evidence == nil {
            sighting.evidence = evidence
        }
        sighting.confidence = max(sighting.confidence, confidence)
        sightings[match] = sighting
    }

    private static func evidence(from jpeg: Data, point: CGPoint) -> Evidence? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let scale = min(1, 600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return Evidence(image: image.preparingThumbnail(of: size) ?? image, point: point)
    }
}

/// The camera pose and intrinsics of one frame, kept so a ray can be cast after the model replies
/// without holding on to the ARFrame itself.
struct CameraSnapshot {
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize

    init(_ camera: ARCamera) {
        transform = camera.transform
        intrinsics = camera.intrinsics
        imageResolution = camera.imageResolution
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
