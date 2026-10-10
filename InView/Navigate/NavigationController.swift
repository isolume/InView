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
        /// Reading the saved map and world map, and building the routing grids, off the main thread.
        case loading
        case noMap
        case locating
        case ready
        case routing
        case navigating
        case arrived
        case noRoute
    }

    @Published private(set) var phase: Phase = .loading
    /// Set once relocalization has taken long enough that the rider should see the fallback.
    @Published private(set) var isRelocalizationSlow = false
    @Published private(set) var route: Route?
    /// The last thing said aloud, shown as a caption for anyone who can't hear it.
    @Published private(set) var caption: String?

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    /// The camera view where the scan started, shown while relocalizing.
    @Published private(set) var startView: UIImage?

    private static let rerouteInterval: TimeInterval = 1
    /// Reading the depth map is the costliest thing a tick does; a chair in the way can wait a second.
    private static let obstacleCheckInterval: TimeInterval = 1
    private static let arrivalDistance: Float = 1.2
    private static let slowRelocalization: TimeInterval = 15
    /// A routine reroute only runs once the rider has moved this far; standing still, the route is still right.
    private static let rerouteDistance: Float = 0.4

    private var map: VenueMap?
    private var worldMap: ARWorldMap?
    private var planner: RoutePlanner?
    private let voice = VoiceGuide()
    private let narrator = Narrator()
    private let obstacles = ObstacleTracker()
    private var renderer: PathRenderer?
    private var timer: Timer?
    private var locatingSince = Date.now
    private var isRouting = false
    private var pendingReason: Narrator.Reason?
    private var lastRouted = Date.distantPast
    private var lastRoutedFrom: SIMD2<Float>?
    private var lastObstacleCheck = Date.distantPast
    /// Between start() and stop(); a load that finishes after stop() doesn't start the session.
    private var isActive = false

    /// Everything read from disk, moved as one value from the loading task.
    private struct Loaded: @unchecked Sendable {
        let map: VenueMap?
        let worldMap: ARWorldMap?
        let planner: RoutePlanner?
        let startView: UIImage?
    }

    /// Loads the map off the main thread, then starts relocalizing. Unarchiving the world map and building
    /// three routing grids used to block the UI for the first seconds of every session.
    func start() {
        guard !isActive else { return }
        isActive = true
        guard phase == .loading else {
            begin()
            return
        }
        Task { [weak self] in
            let started = Date.now
            let loaded = await Task.detached(priority: .userInitiated) {
                let map = MapStore.load()
                return Loaded(map: map, worldMap: MapStore.loadWorldMap(), planner: map.map(RoutePlanner.init), startView: MapStore.loadStartView())
            }.value
            guard let self else { return }
            Log.navigation.info("map loaded in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s · \(loaded.map?.footprints.count ?? 0) footprints, \(loaded.map?.points.count ?? 0) points, world map \(loaded.worldMap == nil ? "missing" : "present", privacy: .public)")
            map = loaded.map
            worldMap = loaded.worldMap
            planner = loaded.planner
            startView = loaded.startView
            phase = map == nil || worldMap == nil ? .noMap : .locating
            if isActive { begin() }
        }
    }

    func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
        voice.deactivate()
        arView.session.pause()
    }

    private func begin() {
        guard phase == .locating, timer == nil, let worldMap else { return }
        run(initialWorldMap: worldMap)
        locatingSince = .now
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        voice.activate()
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

    /// Relocalization plus the two things routing needs: floor planes for the marker height, and scene depth
    /// for obstacles. No scene reconstruction mesh and no occlusion: they cost more tracking headroom than
    /// hiding arrows behind walls is worth.
    private func run(initialWorldMap: ARWorldMap?) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = initialWorldMap
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
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
        guard Date.now.timeIntervalSince(lastRouted) >= Self.rerouteInterval, let position = userPosition() else { return }
        if let from = lastRoutedFrom, simd_distance(from, position) < Self.rerouteDistance {
            // Not worth an A* search; just notice if they've rolled up to the destination.
            if hasArrived(on: route) { requestRoute(.update) }
            return
        }
        requestRoute(.update)
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
        lastRoutedFrom = position
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
