import ARKit
import AccessCore
import Combine
import RealityKit
import UIKit

/// The map and camera share one navigation session, including spoken directions and live obstacles.
@MainActor
final class NavigationController: ObservableObject {
    enum Phase: Equatable {
        /// Disk reads and routing grids are prepared away from the main thread.
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
    @Published private(set) var isRelocalizationSlow = false
    @Published private(set) var route: Route?
    @Published private(set) var selectedDestination: AccessPoint?
    @Published private(set) var caption: String?
    @Published private(set) var map: VenueMap?
    @Published private(set) var position: SIMD2<Float>?
    /// Radians clockwise from -Z toward +X.
    @Published private(set) var heading: Float = 0
    @Published private(set) var startView: UIImage?

    let isDemo: Bool
    lazy var arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    private static let rerouteInterval: TimeInterval = 1
    /// Reading depth is the costliest tick; a newly moved chair can wait a second.
    private static let obstacleCheckInterval: TimeInterval = 1
    private static let arrivalDistance: Float = 1.2
    private static let slowRelocalization: TimeInterval = 15

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
    private var lastObstacleCheck = Date.distantPast
    private var isActive = false
    private var isLoading = false
    private var routingGeneration = 0
    private var demoPath: [SIMD2<Float>] = []
    private var demoDistance: Float = 0
    private var lastDemoTick = Date.now

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        if isDemo {
            map = NavigationDemo.map
            planner = map.map(RoutePlanner.init)
            position = NavigationDemo.startPosition
            heading = NavigationDemo.heading
            route = NavigationDemo.route
            selectedDestination = route?.destination
            phase = map == nil ? .noMap : .ready
        }
    }

    private struct Loaded: @unchecked Sendable {
        let map: VenueMap?
        let worldMap: ARWorldMap?
        let planner: RoutePlanner?
        let startView: UIImage?
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        guard phase == .loading else {
            begin()
            return
        }
        guard !isLoading else { return }
        isLoading = true
        Task { [weak self] in
            let started = Date.now
            let loaded = await Task.detached(priority: .userInitiated) {
                let map = MapStore.load()
                return Loaded(map: map, worldMap: MapStore.loadWorldMap(),
                              planner: map.map(RoutePlanner.init), startView: MapStore.loadStartView())
            }.value
            guard let self else { return }
            Log.navigation.info("map loaded in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s · \(loaded.map?.footprints.count ?? 0) footprints, \(loaded.map?.points.count ?? 0) points, world map \(loaded.worldMap == nil ? "missing" : "present", privacy: .public)")
            isLoading = false
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
        routingGeneration += 1
        isRouting = false
        pendingReason = nil
        if phase == .routing { phase = .ready }
        voice.deactivate()
        if !isDemo { arView.session.pause() }
    }

    private func begin() {
        guard timer == nil, phase != .noMap else { return }
        if isDemo {
            lastDemoTick = .now
        } else {
            guard let worldMap else { return }
            run(initialWorldMap: worldMap)
            if phase == .locating { locatingSince = .now }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        voice.activate()
    }

    func setGeographicReference(_ reference: BuildingMapReference) throws {
        try reference.validate()
        guard map != nil else { return }
        if !isDemo { try MapStore.updateGeographicReference(reference) }
        map?.geographicReference = reference
    }

    /// GPS may adjust the map origin only when camera tracking is current and reliable.
    var placementPosition: SIMD2<Float>? {
        if isDemo { return position }
        guard let frame = arView.session.currentFrame,
              case .normal = frame.camera.trackingState,
              ProcessInfo.processInfo.systemUptime - frame.timestamp < 1 else { return nil }
        let translation = frame.camera.transform.translation
        return SIMD2(translation.x, translation.z)
    }

    func startFromScanOrigin() {
        guard phase == .locating else { return }
        run(initialWorldMap: nil)
        didLocate()
    }

    func navigateToNearest() {
        guard phase == .ready || phase == .noRoute || phase == .arrived,
              planner != nil, userPosition() != nil else { return }
        routingGeneration += 1
        isRouting = false
        pendingReason = nil
        narrator.reset()
        obstacles.reset()
        phase = .routing
        requestRoute(.started)
    }

    func selectDestination(_ destination: AccessPoint?) {
        guard phase == .ready || phase == .arrived || phase == .noRoute else { return }
        routingGeneration += 1
        isRouting = false
        pendingReason = nil
        selectedDestination = destination
        route = nil
        caption = nil
        renderer?.clearRoute()
        phase = .ready
        guard let planner, let position = userPosition() else { return }
        let generation = routingGeneration
        let conditions = conditions
        Task { [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                if let destination { return planner.route(from: position, to: destination, conditions: conditions) }
                return planner.nearestRoute(from: position, conditions: conditions)
            }.value
            guard let self, routingGeneration == generation, phase == .ready else { return }
            route = preview
        }
    }

    func endNavigation() {
        routingGeneration += 1
        isRouting = false
        pendingReason = nil
        caption = nil
        voice.stop()
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

    /// Only floor planes and scene depth are needed. Navigation avoids reconstruction and occlusion.
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
        if isDemo { tickDemo(); return }
        guard let frame = arView.session.currentFrame else { return }
        guard phase != .locating else {
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
        let translation = arView.session.currentFrame?.camera.transform.translation
        position = translation.map { SIMD2($0.x, $0.z) }
        renderer = PathRenderer(scene: arView.scene, map: map)
        phase = .ready
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var conditions: RouteConditions {
        RouteConditions(obstacles: obstacles.obstacles)
    }

    /// Requests during computation run afterward; stopped or replaced sessions reject stale results.
    private func requestRoute(_ reason: Narrator.Reason) {
        guard !isRouting else {
            if case .update = reason, pendingReason != nil { return }
            pendingReason = reason
            return
        }
        guard let planner, let position = userPosition() else { return }
        isRouting = true
        let generation = routingGeneration
        let current = route
        let destination = selectedDestination
        let conditions = conditions
        let fresh: Bool
        if case .started = reason { fresh = true } else { fresh = current == nil }
        Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) {
                // A chosen destination stays chosen when a passage becomes blocked.
                if let destination { return planner.route(from: position, to: destination, conditions: conditions) }
                if fresh || current == nil {
                    return planner.nearestRoute(from: position, conditions: conditions)
                }
                return planner.reroute(current!, from: position, conditions: conditions)
            }.value
            guard let self, routingGeneration == generation, isActive else { return }
            if isDemo, case .started = reason {
                demoPath = next?.waypoints ?? []
                demoDistance = 0
                lastDemoTick = .now
            }
            apply(next, reason: reason)
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
        if let lowest = floorHeights.min() { renderer?.setFloorHeight(lowest) }
    }

    /// The demo moves along a real planner path and never runs an AR session.
    private func tickDemo() {
        let now = Date.now
        let elapsed = Float(min(0.25, now.timeIntervalSince(lastDemoTick)))
        lastDemoTick = now
        guard phase == .navigating, demoPath.count > 1 else { return }
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
            requestRoute(.update)
        }
    }

    private func userPosition() -> SIMD2<Float>? {
        if isDemo { return position }
        guard let frame = arView.session.currentFrame else { return nil }
        let translation = frame.camera.transform.translation
        return SIMD2(translation.x, translation.z)
    }
}
