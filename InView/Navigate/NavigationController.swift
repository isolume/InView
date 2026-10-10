import ARKit
import AccessCore
import Combine
import RealityKit
import UIKit

/// Drives a navigation session: relocalize against the saved AR map, route the user to the nearest
/// usable access point, and keep re-routing as they move and as the camera spots obstacles.
/// Every change is spoken and captioned.
@MainActor
final class NavigationController: ObservableObject {
    enum Phase: Equatable {
        case noMap
        case locating
        case ready
        case routing
        case navigating
        case arrived
        case noRoute
    }

    @Published private(set) var phase: Phase
    /// Set once relocalization has taken long enough that the rider should see the fallback.
    @Published private(set) var isRelocalizationSlow = false
    @Published private(set) var route: Route?
    /// The last thing said aloud, shown as a caption for anyone who can't hear it.
    @Published private(set) var caption: String?

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let startView = MapStore.loadStartView()

    private static let rerouteInterval: TimeInterval = 1
    private static let obstacleCheckInterval: TimeInterval = 0.5
    private static let arrivalDistance: Float = 1.2
    private static let slowRelocalization: TimeInterval = 15

    private let map: VenueMap?
    private let worldMap: ARWorldMap?
    private let planner: RoutePlanner?
    private let voice = VoiceGuide()
    private let narrator = Narrator()
    private let obstacles = ObstacleTracker()
    private var renderer: PathRenderer?
    private var timer: Timer?
    private var locatingSince = Date.now
    private var isRouting = false
    private var pendingReason: Narrator.Reason?
    private var lastRouted = Date.distantPast
    private var lastObstacleCheck = Date.distantPast

    init(map: VenueMap? = MapStore.load(), worldMap: ARWorldMap? = MapStore.loadWorldMap()) {
        self.map = map
        self.worldMap = worldMap
        planner = map.map(RoutePlanner.init)
        phase = map == nil || worldMap == nil ? .noMap : .locating
    }

    func start() {
        guard phase == .locating, timer == nil, let worldMap else { return }
        run(initialWorldMap: worldMap)
        locatingSince = .now
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        voice.activate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        voice.deactivate()
        arView.session.pause()
    }

    /// Fallback when relocalization stalls: restart tracking here and treat this spot as where
    /// the scan began. Only lines up if the rider stands there facing the way the start photo does.
    func startFromScanOrigin() {
        guard phase == .locating else { return }
        run(initialWorldMap: nil)
        didLocate()
    }

    func navigateToNearest() {
        guard phase == .ready || phase == .noRoute || phase == .arrived else { return }
        narrator.reset()
        obstacles.reset()
        phase = .routing
        requestRoute(.started)
    }

    func endNavigation() {
        route = nil
        caption = nil
        voice.stop()
        renderer?.clearRoute()
        phase = .ready
    }

    private func run(initialWorldMap: ARWorldMap?) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = initialWorldMap
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            // Lets real walls hide the arrows behind them.
            configuration.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func tick() {
        guard let frame = arView.session.currentFrame else { return }
        guard phase != .locating else {
            // With an initial world map, tracking stays limited until ARKit has relocalized into the scan's coordinates.
            if case .normal = frame.camera.trackingState {
                didLocate()
            } else if !isRelocalizationSlow, Date.now.timeIntervalSince(locatingSince) > Self.slowRelocalization {
                isRelocalizationSlow = true
            }
            return
        }
        updateFloorHeight(from: frame)
        guard phase == .navigating, let route, let renderer else { return }

        if Date.now.timeIntervalSince(lastObstacleCheck) >= Self.obstacleCheckInterval {
            lastObstacleCheck = .now
            let appeared = obstacles.update(with: frame, route: route.waypoints, floorY: renderer.floorY)
            renderer.showObstacles(obstacles.obstacles)
            if appeared {
                requestRoute(.obstacle)
                return
            }
        }
        if Date.now.timeIntervalSince(lastRouted) >= Self.rerouteInterval {
            requestRoute(.update)
        }
    }

    private func didLocate() {
        guard let map else { return }
        renderer = PathRenderer(scene: arView.scene, map: map)
        phase = .ready
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var conditions: RouteConditions {
        RouteConditions(obstacles: obstacles.obstacles)
    }

    /// Computes a route off the main thread. Requests that arrive mid-computation run right after it.
    private func requestRoute(_ reason: Narrator.Reason) {
        guard !isRouting else {
            if case .update = reason, pendingReason != nil { return }
            pendingReason = reason
            return
        }
        guard let planner, let position = userPosition() else { return }
        isRouting = true
        let current = route
        let conditions = conditions
        let fresh: Bool
        if case .started = reason { fresh = true } else { fresh = current == nil }
        Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) {
                fresh || current == nil
                    ? planner.nearestRoute(from: position, conditions: conditions)
                    : planner.reroute(current!, from: position, conditions: conditions)
            }.value
            self?.apply(next, reason: reason)
        }
    }

    private func apply(_ newRoute: Route?, reason: Narrator.Reason) {
        isRouting = false
        lastRouted = .now
        defer {
            if let pending = pendingReason, phase == .navigating {
                pendingReason = nil
                requestRoute(pending)
            }
        }
        // The user may have ended navigation while the route was computing.
        guard phase == .routing || phase == .navigating else { return }
        guard let newRoute else {
            route = nil
            renderer?.clearRoute()
            phase = .noRoute
            say(Narrator.Line(text: "There's no step-free route from here right now.", isUrgent: true))
            return
        }
        route = newRoute
        if hasArrived(on: newRoute) {
            phase = .arrived
            renderer?.showArrival(at: newRoute.destination)
            say(narrator.arrival(at: newRoute.destination))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            phase = .navigating
            renderer?.show(newRoute)
            narrator.lines(for: newRoute, reason: reason).forEach(say)
        }
    }

    private func say(_ line: Narrator.Line) {
        caption = line.text
        voice.say(line.text, interrupting: line.isUrgent)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: line.text)
        }
    }

    private func hasArrived(on route: Route) -> Bool {
        guard let position = userPosition() else { return false }
        return route.length <= Self.arrivalDistance
            || simd_distance(position, route.destination.floorPoint) <= Self.arrivalDistance
    }

    private func updateFloorHeight(from frame: ARFrame) {
        let floorHeights = frame.anchors
            .compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.classification == .floor }
            .map(\.transform.translation.y)
        if let lowest = floorHeights.min() {
            renderer?.setFloorHeight(lowest)
        }
    }

    private func userPosition() -> SIMD2<Float>? {
        guard let frame = arView.session.currentFrame else { return nil }
        let position = frame.camera.transform.translation
        return SIMD2(position.x, position.z)
    }
}
