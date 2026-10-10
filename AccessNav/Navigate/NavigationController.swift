import ARKit
import AccessCore
import Combine
import RealityKit
import UIKit

/// Drives a navigation session: find the marker, then route the user to the nearest
/// access point and keep re-routing as they move.
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
    @Published private(set) var markerProgress = 0.0
    @Published private(set) var route: Route?

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    private static let rerouteInterval: TimeInterval = 1
    private static let arrivalDistance: Float = 1.2

    private let map: VenueMap?
    private let planner: RoutePlanner?
    private var renderer: PathRenderer?
    private var venue: VenueFrame?
    private var sampler = MarkerSampler()
    private var timer: Timer?
    private var isRouting = false
    private var lastRouted = Date.distantPast

    init(map: VenueMap? = MapStore.load()) {
        self.map = map
        planner = map.map(RoutePlanner.init)
        phase = map == nil ? .noMap : .locating
    }

    func start() {
        guard map != nil, timer == nil, let marker = Marker.referenceImage else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.detectionImages = [marker]
        configuration.maximumNumberOfTrackedImages = 1
        configuration.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            // Lets real walls hide the arrows behind them.
            configuration.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        arView.session.pause()
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

    private func tick() {
        guard let frame = arView.session.currentFrame else { return }
        guard let venue else {
            locateMarker(in: frame)
            return
        }
        updateFloorHeight(from: frame, venue: venue)
        if phase == .navigating, !isRouting, Date.now.timeIntervalSince(lastRouted) >= Self.rerouteInterval {
            reroute()
        }
    }

    private func locateMarker(in frame: ARFrame) {
        sampler.add(frame)
        markerProgress = sampler.progress
        guard let venue = sampler.venueFrame, let map else { return }
        self.venue = venue
        renderer = PathRenderer(scene: arView.scene, venue: venue, map: map)
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

    private func updateFloorHeight(from frame: ARFrame, venue: VenueFrame) {
        let floorHeights = frame.anchors
            .compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.classification == .floor }
            .map { venue.toVenue($0.transform.translation).y }
        if let lowest = floorHeights.min() {
            renderer?.setFloorHeight(lowest)
        }
    }

    private func userPosition() -> SIMD2<Float>? {
        guard let venue, let frame = arView.session.currentFrame else { return nil }
        let position = venue.toVenue(frame.camera.transform.translation)
        return SIMD2(position.x, position.z)
    }
}
