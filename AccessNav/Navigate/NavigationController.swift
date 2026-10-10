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
    @Published private(set) var selectedDestination: AccessPoint?
    @Published private(set) var position: SIMD2<Float>?
    /// Radians: zero faces -Z, positive rotates toward +X.
    @Published private(set) var heading: Float = 0

    let isDemo: Bool

    lazy var arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    let startView: UIImage?

    private static let rerouteInterval: TimeInterval = 1
    private static let arrivalDistance: Float = 1.2
    private static let slowRelocalization: TimeInterval = 15

    let map: VenueMap?
    private let worldMap: ARWorldMap?
    private let planner: RoutePlanner?
    private var renderer: PathRenderer?
    private var timer: Timer?
    private var locatingSince = Date.now
    private var isRouting = false
    private var lastRouted = Date.distantPast
    private var routingGeneration = 0
    private var demoPath: [SIMD2<Float>] = []
    private var demoDistance: Float = 0
    private var lastDemoTick = Date.now

    init(isDemo: Bool = false, map: VenueMap? = nil, worldMap: ARWorldMap? = nil) {
        self.isDemo = isDemo
        let navigationMap = isDemo ? NavigationDemo.map : (map ?? MapStore.load())
        self.map = navigationMap
        self.worldMap = isDemo ? nil : (worldMap ?? MapStore.loadWorldMap())
        startView = isDemo ? nil : MapStore.loadStartView()
        planner = navigationMap.map(RoutePlanner.init)
        if isDemo {
            position = NavigationDemo.startPosition
            heading = NavigationDemo.heading
            let initialRoute = NavigationDemo.route
            route = initialRoute
            selectedDestination = initialRoute?.destination
            phase = navigationMap == nil ? .noMap : .ready
        } else {
            phase = navigationMap == nil || self.worldMap == nil ? .noMap : .locating
        }
    }

    func start() {
        guard timer == nil else { return }
        if isDemo {
            lastDemoTick = .now
        } else {
            guard phase == .locating, let worldMap else { return }
            run(initialWorldMap: worldMap)
            locatingSince = .now
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        routingGeneration += 1
        if !isDemo { arView.session.pause() }
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
        routingGeneration += 1
        let generation = routingGeneration
        let destination = selectedDestination
        Task { [weak self] in
            let route = await Task.detached(priority: .userInitiated) {
                if let destination { return planner.route(from: position, to: destination) }
                return planner.nearestRoute(from: position)
            }.value
            guard let self, self.routingGeneration == generation else { return }
            if self.isDemo {
                self.demoPath = route?.waypoints ?? []
                self.demoDistance = 0
                self.lastDemoTick = .now
            }
            self.apply(route)
        }
    }

    func selectDestination(_ destination: AccessPoint?) {
        guard phase == .ready || phase == .arrived || phase == .noRoute else { return }
        routingGeneration += 1
        isRouting = false
        selectedDestination = destination
        route = nil
        phase = .ready
        guard let planner, let position = userPosition() else { return }
        let generation = routingGeneration
        Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                if let destination { return planner.route(from: position, to: destination) }
                return planner.nearestRoute(from: position)
            }.value
            guard let self, self.routingGeneration == generation, self.phase == .ready else { return }
            self.route = preview
        }
    }

    func endNavigation() {
        routingGeneration += 1
        isRouting = false
        renderer?.clearRoute()
        if isDemo {
            position = NavigationDemo.startPosition
            heading = NavigationDemo.heading
            route = NavigationDemo.route
            selectedDestination = route?.destination
            demoPath = []
            demoDistance = 0
        } else {
            route = nil
        }
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
        if isDemo { tickDemo(); return }
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
        let transform = frame.camera.transform
        position = SIMD2(transform.columns.3.x, transform.columns.3.z)
        heading = atan2(-transform.columns.2.x, transform.columns.2.z)
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
        let generation = routingGeneration
        Task { [weak self] in
            let updated = await Task.detached(priority: .userInitiated) { planner.reroute(route, from: position) }.value
            guard let self, self.routingGeneration == generation else { return }
            self.apply(updated)
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
            UIAccessibility.post(notification: .announcement, argument: "Arrived at the \(newRoute.destination.title)")
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

    /// The demo moves along the planner's measured path; it never runs or overwrites an AR session.
    private func tickDemo() {
        let now = Date.now
        let elapsed = Float(min(0.25, now.timeIntervalSince(lastDemoTick)))
        lastDemoTick = now
        guard phase == .navigating, demoPath.count > 1, let planner, let route else { return }
        demoDistance += elapsed * 0.35
        var remaining = demoDistance
        var nextPosition = demoPath.last!
        for (a, b) in zip(demoPath, demoPath.dropFirst()) {
            let length = simd_distance(a, b)
            if remaining <= length, length > 0 {
                nextPosition = a + (b - a) * (remaining / length)
                heading = atan2(b.x - a.x, -(b.y - a.y))
                break
            }
            remaining -= length
        }
        position = nextPosition
        if Date.now.timeIntervalSince(lastRouted) >= Self.rerouteInterval {
            apply(planner.reroute(route, from: nextPosition))
        }
    }

    private func userPosition() -> SIMD2<Float>? {
        if isDemo { return position }
        guard let frame = arView.session.currentFrame else { return nil }
        let position = frame.camera.transform.translation
        return SIMD2(position.x, position.z)
    }
}
