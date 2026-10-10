import ARKit
import AccessCore
import Combine
import RealityKit
import UIKit

/// Drives a navigation session: relocalize against the saved AR map, then route the user to the
/// nearest access point and keep re-routing as they move.
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

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let startView = MapStore.loadStartView()

    private static let rerouteInterval: TimeInterval = 1
    private static let arrivalDistance: Float = 1.2
    private static let slowRelocalization: TimeInterval = 15

    private let map: VenueMap?
    private let worldMap: ARWorldMap?
    private let planner: RoutePlanner?
    private var renderer: PathRenderer?
    private var timer: Timer?
    private var locatingSince = Date.now
    private var isRouting = false
    private var lastRouted = Date.distantPast

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
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
        guard phase == .ready || phase == .noRoute || phase == .arrived,
              let planner, let position = userPosition() else { return }
        phase = .routing
        isRouting = true
        Task { [weak self] in
            let route = await Task.detached(priority: .userInitiated) { planner.nearestRoute(from: position) }.value
            self?.apply(route)
        }
    }

    func endNavigation() {
        route = nil
        renderer?.clearRoute()
        phase = .ready
    }

    private func run(initialWorldMap: ARWorldMap?) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = initialWorldMap
        configuration.planeDetection = [.horizontal]
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
        if phase == .navigating, !isRouting, Date.now.timeIntervalSince(lastRouted) >= Self.rerouteInterval {
            reroute()
        }
    }

    private func didLocate() {
        guard let map else { return }
        renderer = PathRenderer(scene: arView.scene, map: map)
        phase = .ready
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func reroute() {
        guard let planner, let route, let position = userPosition() else { return }
        isRouting = true
        Task { [weak self] in
            let updated = await Task.detached(priority: .userInitiated) { planner.reroute(route, from: position) }.value
            self?.apply(updated)
        }
    }

    private func apply(_ newRoute: Route?) {
        isRouting = false
        lastRouted = .now
        // The user may have ended navigation while the route was computing.
        guard phase == .routing || phase == .navigating else { return }
        guard let newRoute else {
            route = nil
            renderer?.clearRoute()
            phase = .noRoute
            return
        }
        route = newRoute
        if hasArrived(on: newRoute) {
            phase = .arrived
            renderer?.showArrival(at: newRoute.destination)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: "Arrived at the \(newRoute.destination.kind.title.lowercased())")
        } else {
            phase = .navigating
            renderer?.show(newRoute)
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
