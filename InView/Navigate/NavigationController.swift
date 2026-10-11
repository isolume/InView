import ARKit
import AccessCore
import Combine
import RealityKit
import UIKit

/// The map and camera share one navigation session, including spoken directions and live obstacles.
/// The map shows as soon as it's loaded; the camera only runs once the rider asks for directions or AR.
@MainActor
final class NavigationController: ObservableObject {
    enum Phase: Equatable {
        /// Disk reads and routing grids are prepared away from the main thread.
        case loading
        case noMap
        /// The map is showing and the camera is off.
        case browsing
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
    @Published private(set) var map: VenueMap? {
        didSet { mapRevision &+= 1 }
    }
    @Published private(set) var position: SIMD2<Float>?
    /// Radians clockwise from -Z toward +X.
    @Published private(set) var heading: Float = 0
    @Published private(set) var startView: UIImage?
    /// Directions need the scan's AR map to find the rider; a map without one can still be explored.
    @Published private(set) var canGuide = false
    @Published private(set) var unavailableReason: String?
    @Published private(set) var usesBundledMap = false
    @Published private(set) var isPositionReliable = false
    @Published private(set) var routePreference = RoutePreference.stepFree

    let isDemo: Bool
    lazy var arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    /// Reads room, exit and restroom signs in the same relocalized session, so they land on the saved map.
    lazy var signReader = SignReader(session: arView.session)

    private static let rerouteInterval: TimeInterval = 1
    /// Reading depth is the costliest tick; a newly moved chair can wait a second.
    private static let obstacleCheckInterval: TimeInterval = 1
    private static let arrivalDistance: Float = 1.2
    private static let slowRelocalization: TimeInterval = 15
    /// A routine reroute only runs once the rider has moved this far; standing still, the route is still right.
    private static let rerouteDistance: Float = 0.4

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
    private var isActive = false
    private var isLoading = false
    private var loadingGeneration = 0
    private var routingGeneration = 0
    private var demoPath: [SIMD2<Float>] = []
    private var demoDistance: Float = 0
    private var lastDemoTick = Date.now
    /// Start the route as soon as the rider is found, when they asked for directions before that.
    private var routesWhenLocated = false
    /// The next route goes to the closest place of the destination's kind, like "the nearest elevator".
    private var prefersNearestOfKind = false
    private var sessionIsRunning = false
    private var placeEditSource: MapStore.PlaceEditSource?
    private var placeEditRequest: UUID?
    private var mapRevision = 0

    /// - Parameter map: The saved map, when the caller already has it, so it shows before loading finishes.
    init(isDemo: Bool = false, map: VenueMap? = nil, usesBundledMap: Bool = false) {
        self.isDemo = isDemo
        self.usesBundledMap = usesBundledMap
        guard isDemo else {
            self.map = map
            return
        }
        self.map = NavigationDemo.map
        planner = self.map.map(RoutePlanner.init)
        position = NavigationDemo.startPosition
        heading = NavigationDemo.heading
        route = NavigationDemo.route
        selectedDestination = route?.destination
        phase = self.map == nil ? .noMap : .ready
    }

    private struct Loaded: @unchecked Sendable {
        let map: VenueMap?
        let worldMap: ARWorldMap?
        let planner: RoutePlanner?
        let startView: UIImage?
        let placeEditSource: MapStore.PlaceEditSource?
    }

    /// Loads what directions need. The demo starts moving; a real map waits for `beginGuidance`.
    func start() {
        guard !isActive else { return }
        isActive = true
        guard phase == .loading else {
            if isDemo { begin() }
            return
        }
        guard !isLoading else { return }
        isLoading = true
        loadingGeneration += 1
        let generation = loadingGeneration
        let bundled = usesBundledMap
        Task { [weak self] in
            let started = Date.now
            let loaded = await Task.detached(priority: .userInitiated) {
                let assets = bundled ? nil : MapStore.loadEditableNavigationAssets()
                let map = bundled ? StudentCenterCatalog.map() : assets?.map
                return Loaded(map: map, worldMap: assets?.worldMap,
                              planner: map.map(RoutePlanner.init), startView: assets?.startView,
                              placeEditSource: assets?.source)
            }.value
            guard let self, generation == loadingGeneration else { return }
            Log.navigation.info("map loaded in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s · \(loaded.map?.footprints.count ?? 0) footprints, \(loaded.map?.points.count ?? 0) points, world map \(loaded.worldMap == nil ? "missing" : "present", privacy: .public)")
            isLoading = false
            map = loaded.map
            placeEditSource = loaded.placeEditSource
            worldMap = loaded.worldMap
            planner = loaded.planner
            startView = loaded.startView
            canGuide = map != nil && worldMap != nil && map?.requiresOptimizedLocalization != true
            unavailableReason = map?.requiresOptimizedLocalization == true
                ? "Live positioning is not ready for this map yet. You can still explore the floor."
                : worldMap == nil ? "AR guidance is not available for this floor yet. You can still explore the map and preview a route." : nil
            phase = map == nil ? .noMap : .browsing
        }
    }

    /// Turns the camera on and finds the rider in the scanned space; then routes, when `thenRoute`.
    func beginGuidance(thenRoute: Bool) {
        guard !isDemo, !isSavingPlaces, isActive, canGuide, map?.requiresOptimizedLocalization != true,
              let worldMap, phase == .browsing else { return }
        routesWhenLocated = thenRoute
        isRelocalizationSlow = false
        phase = .locating
        locatingSince = .now
        run(initialWorldMap: worldMap)
        begin()
    }

    /// Switches to a newly saved map: the session starts over with it.
    func reload(map newMap: VenueMap?, usesBundledMap: Bool = false) {
        guard !isDemo else { return }
        stop()
        // A floor switch invalidates any disk load still preparing the previous floor.
        loadingGeneration += 1
        isLoading = false
        placeEditRequest = nil
        placeEditSource = nil
        isSavingPlaces = false
        map = newMap
        self.usesBundledMap = usesBundledMap
        worldMap = nil
        planner = nil
        startView = nil
        renderer = nil
        canGuide = false
        unavailableReason = nil
        route = nil
        selectedDestination = nil
        caption = nil
        position = nil
        heading = 0
        isPositionReliable = false
        isRelocalizationSlow = false
        phase = .loading
        start()
    }

    /// Public releases contain map geometry; live positioning requires separate, matching evidence.
    func showSharedMap(_ newMap: VenueMap?) {
        stop()
        loadingGeneration += 1
        isLoading = false
        placeEditRequest = nil
        placeEditSource = nil
        isSavingPlaces = false
        map = newMap
        worldMap = nil
        planner = nil
        startView = nil
        renderer = nil
        route = nil
        selectedDestination = nil
        caption = nil
        position = nil
        heading = 0
        canGuide = false
        usesBundledMap = true
        isPositionReliable = false
        isRelocalizationSlow = false
        unavailableReason = "AR guidance is not available for this floor yet. You can still explore the map and preview a route."
        phase = newMap == nil ? .noMap : .browsing
        isActive = true
    }

    /// The camera has found the rider in the scan and is tracking them, with or without a route.
    var isLocated: Bool {
        !isDemo && [.ready, .routing, .navigating, .arrived, .noRoute].contains(phase)
    }

    /// Turns the camera off and returns to exploring the map.
    func endGuidance() {
        guard !isDemo, map != nil else { return }
        stopSession()
        route = nil
        caption = nil
        renderer?.clearRoute()
        routesWhenLocated = false
        prefersNearestOfKind = false
        position = nil
        isPositionReliable = false
        phase = .browsing
    }

    func stop() {
        isActive = false
        stopSession()
        if phase == .routing { phase = .ready }
        // A real session can't resume where it was without the camera; it returns to the map.
        if !isDemo, ![.loading, .noMap].contains(phase) {
            route = nil
            caption = nil
            routesWhenLocated = false
            phase = .browsing
        }
    }

    private func stopSession() {
        timer?.invalidate()
        timer = nil
        routingGeneration += 1
        isRouting = false
        pendingReason = nil
        voice.deactivate()
        if !isDemo, sessionIsRunning { arView.session.pause(); sessionIsRunning = false }
        isPositionReliable = false
    }

    private func begin() {
        guard timer == nil, phase != .noMap else { return }
        if isDemo { lastDemoTick = .now }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        voice.activate()
    }

    /// Only a locally saved floor can be edited, while its camera and directions are off.
    var canEditPlaces: Bool {
        !isDemo && !usesBundledMap && map != nil && placeEditSource != nil
            && phase == .browsing && !isSavingPlaces
    }
    @Published private(set) var isSavingPlaces = false

    func savePlace(_ point: AccessPoint) async throws -> AccessibilityReport {
        guard var edited = map else { throw CaptureValidationError.invalid("There's no map open.") }
        edited.place(point)
        return try await publishPlaces(edited)
    }

    /// Signs can be tagged while the camera is on and the rider is found: reading a sign needs the
    /// live session in the saved map's frame, which is what positions the door it labels.
    var canTagSigns: Bool {
        !isDemo && !usesBundledMap && map != nil && placeEditSource != nil && !isSavingPlaces
    }

    /// Adds a place read from a sign, or updates the one already on that door.
    func tagSign(_ point: AccessPoint) async throws -> (point: AccessPoint, isNew: Bool) {
        guard var edited = map else { throw CaptureValidationError.invalid("There's no map open.") }
        let result = edited.applySign(point)
        _ = try await publishPlaces(edited, whileLive: true)
        return result
    }

    func removePlace(id: UUID) async throws -> AccessibilityReport {
        guard var edited = map else { throw CaptureValidationError.invalid("There's no map open.") }
        edited.removePoint(id: id)
        return try await publishPlaces(edited)
    }

    private func publishPlaces(_ edited: VenueMap, whileLive: Bool = false) async throws -> AccessibilityReport {
        guard whileLive ? canTagSigns : canEditPlaces, let previous = map, let source = placeEditSource else {
            throw CaptureValidationError.invalid("Places can be changed on a saved map while directions are off.")
        }
        let request = UUID()
        let generation = loadingGeneration
        placeEditRequest = request
        isSavingPlaces = true
        defer {
            if placeEditRequest == request { placeEditRequest = nil; isSavingPlaces = false }
        }
        map = edited
        let revision = mapRevision
        if let selected = selectedDestination { selectedDestination = edited.points.first { $0.id == selected.id } }
        let writer = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let planner = RoutePlanner(map: edited)
            let report = try AccessibilityReport.make(map: edited, planner: planner)
            let savedSource = try MapStore.updatePoints(edited.points, report: report, expected: source)
            return (planner, report, savedSource)
        }
        do {
            let saved = try await withTaskCancellationHandler {
                try await writer.value
            } onCancel: {
                writer.cancel()
            }
            guard placeEditRequest == request, loadingGeneration == generation, mapRevision == revision,
                  !usesBundledMap, placeEditSource == source else {
                throw CaptureValidationError.invalid("The open map changed before the edit finished.")
            }
            planner = saved.0
            placeEditSource = saved.2
            return saved.1
        } catch {
            // A late failure must not restore this floor over a newly selected map or a newer edit.
            if placeEditRequest == request, loadingGeneration == generation, mapRevision == revision,
               !usesBundledMap, placeEditSource == source {
                map = previous
                if let selected = selectedDestination { selectedDestination = previous.points.first { $0.id == selected.id } }
            }
            throw error
        }
    }

    func setGeographicReference(_ reference: BuildingMapReference) throws {
        try reference.validate()
        guard map != nil else { return }
        if !isDemo { try MapStore.updateGeographicReference(reference) }
        map?.geographicReference = reference
        if !isDemo, !usesBundledMap, let map { placeEditSource = MapStore.placeEditSource(matching: map) }
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

    /// Retry with the saved coordinate system; routing waits for actual relocalization.
    func retryLocalization() {
        guard phase == .locating, let worldMap else { return }
        isRelocalizationSlow = false
        locatingSince = .now
        run(initialWorldMap: worldMap)
    }

    func navigateToNearest() {
        if phase == .browsing {
            beginGuidance(thenRoute: true)
            return
        }
        if phase == .locating {
            routesWhenLocated = true
            return
        }
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

    /// Discard the previous choice immediately, including in-flight searches and spoken
    /// instructions. A preference change starts a fresh search to the selected destination.
    func setRoutePreference(_ preference: RoutePreference) {
        guard preference != routePreference else { return }
        let wasGuiding = phase == .navigating || phase == .routing || phase == .noRoute
        routePreference = preference
        routingGeneration += 1
        isRouting = false
        pendingReason = nil
        route = nil
        caption = nil
        voice.stop()
        narrator.reset()
        renderer?.clearRoute()
        if wasGuiding {
            phase = .routing
            requestRoute(.started)
        } else if phase == .ready || phase == .arrived {
            phase = .ready
            selectDestination(selectedDestination)
        }
    }

    /// Directions to `destination`, or to the closest place of its kind. The camera only finds the rider;
    /// the route is drawn on the map.
    func navigate(to destination: AccessPoint, nearestOfKind: Bool) {
        guard !isDemo else { selectDestination(destination); navigateToNearest(); return }
        if [.routing, .navigating, .noRoute, .arrived].contains(phase) { endNavigation() }
        selectedDestination = destination
        prefersNearestOfKind = nearestOfKind
        navigateToNearest()
    }

    /// Ends any route and clears the destination. Once the camera has found the rider it keeps
    /// tracking them, so their position stays on the map.
    func clearDirections() {
        if isDemo { selectDestination(nil); return }
        routesWhenLocated = false
        prefersNearestOfKind = false
        if [.ready, .routing, .navigating, .arrived, .noRoute].contains(phase) { endNavigation() }
        selectedDestination = nil
    }

    func selectDestination(_ destination: AccessPoint?) {
        if phase == .browsing || phase == .locating {
            selectedDestination = destination
            return
        }
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
            let destination = selectedDestination ?? NavigationDemo.route?.destination
            route = destination.flatMap { destination in
                planner?.route(from: NavigationDemo.startPosition, to: destination, conditions: conditions)
            }
            selectedDestination = destination
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
        sessionIsRunning = true
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
        guard case .normal = frame.camera.trackingState else {
            if isPositionReliable {
                say(Narrator.Line(text: "Position lost. Stop and look around to reconnect.", isUrgent: true))
            }
            isPositionReliable = false
            position = nil
            renderer?.clearRoute()
            return
        }
        if !isPositionReliable, let route { renderer?.show(route) }
        isPositionReliable = true
        let transform = frame.camera.transform
        position = SIMD2(transform.columns.3.x, transform.columns.3.z)
        heading = atan2(-transform.columns.2.x, transform.columns.2.z)
        updateFloorHeight(from: frame)
        // A preference change may have happened while tracking was unavailable.
        if phase == .routing, !isRouting { requestRoute(.started); return }
        guard phase == .navigating, let route, let renderer else { return }
        if Date.now.timeIntervalSince(lastObstacleCheck) >= Self.obstacleCheckInterval {
            lastObstacleCheck = .now
            let change = obstacles.update(with: frame, route: route.waypoints, floorY: renderer.floorY)
            renderer.showObstacles(obstacles.obstacles)
            if let change {
                requestRoute(change == .appeared ? .obstacle : .update)
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
        let translation = arView.session.currentFrame?.camera.transform.translation
        position = translation.map { SIMD2($0.x, $0.z) }
        isPositionReliable = true
        renderer = PathRenderer(scene: arView.scene, map: map)
        phase = .ready
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if routesWhenLocated {
            routesWhenLocated = false
            navigateToNearest()
        }
    }

    private var conditions: RouteConditions {
        routePreference.conditions(obstacles: obstacles.obstacles)
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
        lastRoutedFrom = position
        let generation = routingGeneration
        let current = route
        let destination = selectedDestination
        let conditions = conditions
        let fresh: Bool
        if case .started = reason { fresh = true } else { fresh = current == nil }
        // "The nearest elevator" is decided by walking distance from where the rider actually is.
        let kind = fresh && prefersNearestOfKind ? destination?.kind : nil
        let candidates = kind.map { kind in planner.map.points.filter { $0.kind == kind } } ?? []
        if fresh { prefersNearestOfKind = false }
        Task { [weak self] in
            let next = await Task.detached(priority: .userInitiated) {
                if !candidates.isEmpty {
                    return candidates.compactMap { planner.route(from: position, to: $0, conditions: conditions) }
                        .min { $0.length < $1.length }
                }
                // A chosen destination stays chosen when a passage becomes blocked.
                if let destination { return planner.route(from: position, to: destination, conditions: conditions) }
                if fresh || current == nil {
                    return planner.nearestRoute(from: position, conditions: conditions)
                }
                return planner.reroute(current!, from: position, conditions: conditions)
            }.value
            guard let self, routingGeneration == generation, isActive else { return }
            if !candidates.isEmpty, let chosen = next?.destination { selectedDestination = chosen }
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
            let message = routePreference == .stepFree
                ? "There's no step-free route from here right now."
                : "There's no route through the mapped floor from here right now."
            say(Narrator.Line(text: message, isUrgent: true))
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
        guard case .normal = frame.camera.trackingState else { return nil }
        let translation = frame.camera.transform.translation
        return SIMD2(translation.x, translation.z)
    }
}
