import AccessCore
import RealityKit
import SwiftUI
import UIKit

/// The scanned floor as a 3D model: drag to orbit, pinch to zoom, double-tap to reset.
struct VenueModelView: UIViewRepresentable {
    let map: VenueMap

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.secondarySystemBackground)
        context.coordinator.attach(to: view, map: map)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    func makeCoordinator() -> OrbitCamera { OrbitCamera() }

    /// Keeps a camera on a sphere around the model and moves it with gestures.
    @MainActor
    final class OrbitCamera: NSObject {
        private let camera = PerspectiveCamera()
        private var target = SIMD3<Float>.zero
        private var defaultDistance: Float = 8
        private var distance: Float = 8
        private var yaw: Float = .pi / 5
        private var pitch: Float = .pi / 4
        private var gestureStart: (yaw: Float, pitch: Float, distance: Float) = (0, 0, 0)

        func attach(to view: ARView, map: VenueMap) {
            let model = VenueModelBuilder.build(map)
            let anchor = AnchorEntity(world: .zero)
            anchor.addChild(model)

            let sun = DirectionalLight()
            sun.light.intensity = 3000
            sun.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
            anchor.addChild(sun)
            anchor.addChild(camera)
            view.scene.addAnchor(anchor)

            let bounds = model.visualBounds(relativeTo: nil)
            target = bounds.center
            defaultDistance = max(4, max(bounds.extents.x, bounds.extents.z) * 1.15)
            distance = defaultDistance
            updateCamera()

            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch)))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(reset))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { gestureStart = (yaw, pitch, distance) }
            let translation = gesture.translation(in: gesture.view)
            yaw = gestureStart.yaw - Float(translation.x) * 0.008
            pitch = min(1.45, max(0.15, gestureStart.pitch + Float(translation.y) * 0.006))
            updateCamera()
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { gestureStart = (yaw, pitch, distance) }
            distance = min(defaultDistance * 3, max(1.5, gestureStart.distance / Float(gesture.scale)))
            updateCamera()
        }

        @objc private func reset() {
            yaw = .pi / 5
            pitch = .pi / 4
            distance = defaultDistance
            camera.move(to: transform(), relativeTo: nil, duration: 0.35, timingFunction: .easeInOut)
        }

        private func updateCamera() {
            camera.transform = transform()
        }

        private func transform() -> Transform {
            let offset = SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
            var transform = Transform()
            transform.translation = target + offset
            transform.rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
            return transform
        }
    }
}

/// The map as a floor plan or a 3D model, with a legend.
///
/// The 3D model is a RealityKit view, and only one RealityKit or AR view should be alive at a time, so it is
/// created only while 3D is picked, and taken down whenever `isModelAllowed` is false (for example while
/// the scan or navigation camera is up over this panel).
struct MapPanel: View {
    enum Style: String, CaseIterable {
        case plan = "Plan"
        case model = "3D"
    }

    let map: VenueMap
    var height: CGFloat = 300
    /// Plan only: tapping reports the floor point under the finger.
    var onTap: ((SIMD2<Float>) -> Void)?
    /// False while another AR or RealityKit view is on screen; the 3D model then gives way to a placeholder.
    var isModelAllowed = true
    @State private var style: Style = .plan

    var body: some View {
        VStack(spacing: 10) {
            Picker("Map style", selection: $style) {
                ForEach(Style.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)

            Group {
                switch style {
                case .plan:
                    MapPreviewView(map: map, onTap: onTap)
                case .model where isModelAllowed:
                    VenueModelView(map: map)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            StatusPill(text: "Drag to orbit · pinch to zoom", isCompact: true)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                case .model:
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .overlay {
                            Label("3D view paused", systemImage: "cube.transparent")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(height: height)

            MapLegend()
        }
    }
}

private struct MapLegend: View {
    var body: some View {
        // The same marks the plan draws: badges for access points, swatches for areas and doors.
        let items: [(String, AnyView)] = [
            ("Elevator", AnyView(KindBadge(kind: AccessPoint.Kind.elevator, size: 18))),
            ("Ramp", AnyView(KindBadge(kind: AccessPoint.Kind.ramp, size: 18))),
            ("Stairs", AnyView(RoundedRectangle(cornerRadius: 3).fill(Theme.stairs.opacity(0.18)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.stairs, lineWidth: 1.5)).frame(width: 16, height: 14))),
            ("Door", AnyView(Capsule().fill(Theme.color(for: .good)).frame(width: 16, height: 5))),
            ("Narrow door", AnyView(Capsule().fill(Theme.color(for: .warning)).frame(width: 16, height: 5))),
            ("Furniture", AnyView(RoundedRectangle(cornerRadius: 3).fill(Theme.furniture.opacity(0.28)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.furniture.opacity(0.8))).frame(width: 16, height: 14))),
        ]
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 6) {
                    item.1.frame(width: 18, height: 18)
                    Text(item.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: elevators blue, ramps teal, stairs red, wide doors green, narrow doors orange, furniture gray")
    }
}
