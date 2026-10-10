import ARKit
import AccessCore
import Combine

/// Samples camera frames during a scan, asks the vision model for elevators and ramps,
/// and pins each one in 3D by casting a ray onto the scanned surfaces.
@MainActor
final class AccessibilityDetector: ObservableObject {
    /// An access point seen during the scan, in ARKit world coordinates.
    struct Sighting: Identifiable {
        let id = UUID()
        var kind: AccessPoint.Kind
        var position: SIMD3<Float>
        var confidence: Float
        var source: AccessPoint.Source
        var count = 1
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

    private let client = OpenAIVisionClient()
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
    func addManual(_ kind: AccessPoint.Kind) {
        guard let session, let frame = session.currentFrame else { return }
        let position = locate(CGPoint(x: 0.5, y: 0.5), camera: CameraSnapshot(frame.camera), in: session)
        record(kind, at: position, confidence: 1, source: .manual)
    }

    func accessPoints(in venue: VenueFrame) -> [AccessPoint] {
        sightings.map {
            AccessPoint(kind: $0.kind, position: venue.toVenue($0.position), source: $0.source, confidence: $0.confidence)
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

    private func handle(_ detections: [OpenAIVisionClient.Detection], camera: CameraSnapshot) {
        framesAnalyzed += 1
        lastError = nil
        guard let session else { return }
        for detection in detections where detection.confidence >= Self.minimumConfidence {
            let imagePoint = FrameEncoder.capturedImagePoint(fromPortrait: CGPoint(x: detection.x, y: detection.y))
            record(detection.kind, at: locate(imagePoint, camera: camera, in: session), confidence: detection.confidence, source: .detected)
        }
    }

    /// Casts a ray through a captured-image point onto the scanned surfaces, falling back to a point a few meters out.
    private func locate(_ imagePoint: CGPoint, camera: CameraSnapshot, in session: ARSession) -> SIMD3<Float> {
        let ray = camera.ray(through: imagePoint)
        let query = ARRaycastQuery(origin: ray.origin, direction: ray.direction, allowing: .estimatedPlane, alignment: .any)
        return session.raycast(query).first?.worldTransform.translation ?? ray.origin + ray.direction * 3
    }

    private func record(_ kind: AccessPoint.Kind, at position: SIMD3<Float>, confidence: Float, source: AccessPoint.Source) {
        let match = sightings.firstIndex {
            $0.kind == kind && simd_distance(SIMD2($0.position.x, $0.position.z), SIMD2(position.x, position.z)) < Self.mergeDistance
        }
        guard let match else {
            sightings.append(Sighting(kind: kind, position: position, confidence: confidence, source: source))
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
