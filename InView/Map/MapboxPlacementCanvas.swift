import AccessCore
import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

struct MapboxPlacementCameraTarget: Equatable {
    let latitude: Double
    let longitude: Double
    let revision = UUID()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The geographic origin follows the native map's center during user gestures.
/// Only explicit search or GPS targets reposition the camera; changing the
/// outline's orientation never moves or resets the map beneath it.
struct MapboxPlacementCanvas: UIViewRepresentable {
    let map: VenueMap
    @Binding var reference: BuildingMapReference?
    let heading: Double
    let cameraTarget: MapboxPlacementCameraTarget?
    let accessToken: String

    func makeUIView(context: Context) -> MapboxMaps.MapView {
        MapboxOptions.accessToken = accessToken
        let options = MapInitOptions(
            mapStyle: InViewMapboxStyle.placement,
            cameraOptions: CameraOptions(center: cameraTarget?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                         zoom: cameraTarget == nil ? 1 : 18.5, bearing: 0, pitch: 0),
            antialiasingSampleCount: 4)
        let view = MapboxMaps.MapView(frame: .zero, mapInitOptions: options)
        var gestures = view.gestures.options
        gestures.rotateEnabled = false
        gestures.pitchEnabled = false
        gestures.simultaneousRotateAndPinchZoomEnabled = false
        view.gestures.options = gestures
        var ornaments = view.ornaments.options
        ornaments.compass.visibility = .hidden
        ornaments.scaleBar.visibility = .hidden
        view.ornaments.options = ornaments
        view.accessibilityLabel = "Building placement map"
        context.coordinator.mapView = view
        view.gestures.delegate = context.coordinator
        context.coordinator.observeCamera()
        context.coordinator.update(self)
        return view
    }

    func updateUIView(_ uiView: MapboxMaps.MapView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ uiView: MapboxMaps.MapView, coordinator: Coordinator) {
        uiView.gestures.delegate = nil
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: GestureManagerDelegate {
        weak var mapView: MapboxMaps.MapView?
        private var content: MapboxPlacementCanvas?
        private var lastCameraTarget: MapboxPlacementCameraTarget?
        private var cameraObservation: AnyCancelable?
        private var activeGestures = Set<GestureType>()
        private var animatedGestures = Set<GestureType>()

        func observeCamera() {
            cameraObservation = mapView?.mapboxMap.onCameraChanged.observe { [weak self] _ in
                guard let self, !self.activeGestures.isEmpty || !self.animatedGestures.isEmpty else { return }
                self.publishCenter()
            }
        }

        func stop() {
            cameraObservation?.cancel()
            cameraObservation = nil
            mapView = nil
        }

        func update(_ value: MapboxPlacementCanvas) {
            guard let mapView else { return }
            content = value
            if let target = value.cameraTarget, lastCameraTarget != target {
                lastCameraTarget = target
                activeGestures.removeAll()
                animatedGestures.removeAll()
                mapView.camera.cancelAnimations()
                mapView.mapboxMap.setCamera(to: CameraOptions(center: target.coordinate, zoom: 18.5, bearing: 0, pitch: 0))
            }
            let features = value.map.footprints.filter { $0.kind == .wall }.compactMap { footprint -> Feature? in
                guard let reference = value.reference else { return nil }
                let coordinates = footprint.corners.compactMap { point -> CLLocationCoordinate2D? in
                    guard let coordinate = try? reference.coordinate(for: point) else { return nil }
                    return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                guard coordinates.count == footprint.corners.count, let first = coordinates.first else { return nil }
                return Feature(geometry: Polygon([coordinates + [first]]))
            }
            mapView.mapboxMap.setMapStyleContent {
                GeoJSONSource(id: "inview-placement-outline").data(.featureCollection(.init(features: features)))
                FillLayer(id: "inview-placement-walls", source: "inview-placement-outline")
                    .fillColor(Theme.accentUIColor)
                    .fillOpacity(0.65)
                    .slot(.top)
            }
        }

        private func publishCenter() {
            guard let mapView, let content else { return }
            let coordinate = mapView.mapboxMap.cameraState.center
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            if let previous = content.reference,
               abs(previous.latitude - coordinate.latitude) < 0.000000001,
               abs(previous.longitude - coordinate.longitude) < 0.000000001 { return }
            content.reference = BuildingMapReference(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                                     headingDegrees: content.heading,
                                                     horizontalAccuracyM: content.reference?.horizontalAccuracyM)
        }

        func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
            activeGestures.insert(gestureType)
        }

        func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {
            publishCenter()
            activeGestures.remove(gestureType)
            if willAnimate { animatedGestures.insert(gestureType) }
        }

        func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {
            publishCenter()
            animatedGestures.remove(gestureType)
        }
    }
}
