import ARKit
import AccessCore
import Combine

/// Samples camera frames during a scan, asks Gemini for elevators and ramps, pins each one in 3D
/// by casting a ray onto the scanned surfaces, and measures ramp slopes from the LiDAR surface.
@MainActor
final class AccessibilityDetector: ObservableObject {
    /// An access point seen during the scan, in ARKit world coordinates.
    struct Sighting: Identifiable {
        let id = UUID()
        var kind: AccessPoint.Kind
        var name: String
        var position: SIMD3<Float>
        var confidence: Float
        var source: AccessPoint.Source
        var count = 1
        /// Every slope measurement so far; the median is reported.
        var slopes: [Float] = []

        var slopeDegrees: Float? {
            slopes.isEmpty ? nil : slopes.sorted()[slopes.count / 2]
        }
    }

    @Published private(set) var sightings: [Sighting] = []
    @Published private(set) var framesAnalyzed = 0
    @Published private(set) var lastError: String?

    var isEnabled: Bool { client != nil }

    private static let sampleInterval: TimeInterval = 2
    private static let maxRequestsInFlight = 2
    private static let minimumConfidence: Float = 0.6
    /// Sightings of the same kind closer than this are treated as the same place.
    private static let mergeDistance: Float = 2
    /// Slope samples form a grid this wide around the surface point, in normalized image units.
    private static let slopeSampleSpan: CGFloat = 0.08
    private static let slopeSampleSteps = 7

    private let client = GeminiVisionClient()
    private weak var session: ARSession?
    private var timer: Timer?
    private var requestsInFlight = 0

    func start(session: ARSession) {
        self.session = session
        resume()
    }

    func resume() {
        guard timer == nil, isEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.analyzeCurrentFrame() }
        }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Pins an access point where the center of the screen meets the scene. The fallback when the model misses one.
    /// For ramps, aim at the middle of the ramp so its slope can be measured too.
    func addManual(_ kind: AccessPoint.Kind) {
        guard let session, let frame = session.currentFrame else { return }
        let camera = CameraSnapshot(frame.camera)
        let center = CGPoint(x: 0.5, y: 0.5)
        let slope = kind == .ramp ? measureSlope(around: center, camera: camera, in: session) : nil
        let count = sightings.filter { $0.kind == kind }.count
        record(kind, name: "\(kind.title) \(count + 1)", at: locate(center, camera: camera, in: session), confidence: 1, source: .manual, slope: slope)
    }

    func accessPoints() -> [AccessPoint] {
        sightings.map {
            AccessPoint(kind: $0.kind, name: $0.name, position: $0.position, source: $0.source, confidence: $0.confidence, slopeDegrees: $0.slopeDegrees)
        }
    }

    private func analyzeCurrentFrame() {
        guard let client, let session, requestsInFlight < Self.maxRequestsInFlight,
              let frame = session.currentFrame, case .normal = frame.camera.trackingState else { return }
        let camera = CameraSnapshot(frame.camera)
        let pixelBuffer = frame.capturedImage
        requestsInFlight += 1
        Task { [weak self] in
            defer { self?.requestsInFlight -= 1 }
            do {
                let encode = Task.detached(priority: .utility) { FrameEncoder.portraitJPEG(from: pixelBuffer) }
                guard let jpeg = await encode.value else { return }
                let detections = try await client.detect(jpeg: jpeg)
                self?.handle(detections, camera: camera)
            } catch {
                self?.lastError = error.localizedDescription
            }
        }
    }

    private func handle(_ detections: [GeminiVisionClient.Detection], camera: CameraSnapshot) {
        framesAnalyzed += 1
        lastError = nil
        guard let session else { return }
        for detection in detections where detection.confidence >= Self.minimumConfidence {
            guard let target = detection.target else { continue }
            let position = locate(FrameEncoder.capturedImagePoint(fromPortrait: target), camera: camera, in: session)
            var slope: Float?
            if detection.kind == .ramp, let surface = detection.surface {
                slope = measureSlope(around: FrameEncoder.capturedImagePoint(fromPortrait: surface), camera: camera, in: session)
            }
            record(detection.kind, name: detection.name, at: position, confidence: detection.confidence, source: .detected, slope: slope)
        }
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

    private func record(_ kind: AccessPoint.Kind, name: String, at position: SIMD3<Float>, confidence: Float, source: AccessPoint.Source, slope: Float?) {
        let match = sightings.firstIndex {
            $0.kind == kind && simd_distance(SIMD2($0.position.x, $0.position.z), SIMD2(position.x, position.z)) < Self.mergeDistance
        }
        guard let match else {
            var sighting = Sighting(kind: kind, name: name, position: position, confidence: confidence, source: source)
            if let slope { sighting.slopes.append(slope) }
            sightings.append(sighting)
            return
        }
        var sighting = sightings[match]
        if source == .manual {
            // A volunteer's pin beats the model's estimate.
            sighting.position = position
            sighting.source = .manual
        } else if sighting.source == .detected {
            sighting.position += (position - sighting.position) / Float(sighting.count + 1)
        }
        if let slope { sighting.slopes.append(slope) }
        sighting.count += 1
        sighting.confidence = max(sighting.confidence, confidence)
        sightings[match] = sighting
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
