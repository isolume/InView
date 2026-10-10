import RealityKit
import SwiftUI
import UIKit

/// The walkthrough asset can be explored without starting a camera or borrowing the scan's coordinates.
struct BuildingIllustrationView: View {
    var floor = 2
    var showsCaption = true
    @StateObject private var controller = BuildingIllustrationController()

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let url = StudentCenterCatalog.illustrationURL(for: floor) {
                BuildingIllustrationCanvas(url: url, controller: controller)
                switch controller.phase {
                case .loading:
                    ProgressView("Opening 3D view")
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                case .ready:
                    controls
                case .failed:
                    unavailable
                }
            } else {
                unavailable
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showsCaption, controller.phase == .ready {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Floor \(floor)").font(.subheadline.weight(.semibold))
                    Text("Visual reference · Estimated layout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(16)
                .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    control(controller.isTopDown ? "3D" : "2D", label: controller.isTopDown ? "Show 3D view" : "Show top view") {
                        controller.toggleTopView()
                    }
                    Divider().padding(.horizontal, 10)
                    Button(action: controller.reset) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 48, height: 48)
                    }
                    .accessibilityLabel("Reset 3D view")
                }
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
            Spacer()
        }
        .padding(16)
    }

    private func control(_ title: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).frame(width: 48, height: 48)
        }
        .accessibilityLabel(label)
    }

    private var unavailable: some View {
        ContentUnavailableView("3D view unavailable", systemImage: "cube", description: Text("You can still explore the floor map."))
    }
}

private struct BuildingIllustrationCanvas: UIViewRepresentable {
    let url: URL
    let controller: BuildingIllustrationController

    func makeCoordinator() -> BuildingIllustrationController { controller }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.91, green: 0.92, blue: 0.90, alpha: 1))
        view.renderOptions.insert(.disableMotionBlur)
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Floors 2 and 3 building model"
        view.accessibilityValue = "Estimated visual layout"
        view.accessibilityHint = "Drag to rotate, pinch to zoom, or double tap to reset."
        controller.attach(to: view, url: url)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: BuildingIllustrationController) {
        coordinator.detach(from: uiView)
    }
}

@MainActor
private final class BuildingIllustrationController: NSObject, ObservableObject {
    enum Phase { case loading, ready, failed }
    @Published private(set) var phase = Phase.loading
    @Published private(set) var isTopDown = false

    private let camera = PerspectiveCamera()
    private var loadTask: Task<Void, Never>?
    private weak var view: ARView?
    private var target = SIMD3<Float>.zero
    private var defaultDistance: Float = 30
    private var distance: Float = 30
    private var yaw: Float = -.pi / 5
    private var pitch: Float = .pi / 3.6
    private var gestureStart: (yaw: Float, pitch: Float, distance: Float) = (0, 0, 0)

    func attach(to view: ARView, url: URL) {
        loadTask?.cancel()
        self.view = view
        phase = .loading
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(camera)

        let sun = DirectionalLight()
        sun.light.intensity = 2400
        sun.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
        anchor.addChild(sun)
        view.scene.addAnchor(anchor)

        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapReset))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        loadTask = Task { [weak self, weak view] in
            do {
                let model = try await Entity(contentsOf: url)
                guard !Task.isCancelled, let self, let view, self.view === view else { return }
                let bounds = model.visualBounds(relativeTo: nil)
                guard bounds.extents.x.isFinite, bounds.extents.z.isFinite,
                      max(bounds.extents.x, bounds.extents.z) > 0 else {
                    self.phase = .failed
                    return
                }
                anchor.addChild(model)
                self.target = bounds.center
                self.defaultDistance = max(8, max(bounds.extents.x, bounds.extents.z) * 1.65)
                self.distance = self.defaultDistance
                self.updateCamera()
                self.phase = .ready
                if let lighting = await StudioLighting.resource(), !Task.isCancelled, self.view === view {
                    view.environment.lighting.resource = lighting
                    view.environment.lighting.intensityExponent = 0.5
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed
            }
        }
    }

    func detach(from view: ARView) {
        guard self.view === view else { return }
        loadTask?.cancel()
        loadTask = nil
        self.view = nil
        view.scene.anchors.removeAll()
    }

    func reset() {
        yaw = -.pi / 5
        pitch = .pi / 3.6
        distance = defaultDistance
        isTopDown = false
        updateCamera()
    }

    func toggleTopView() {
        isTopDown.toggle()
        pitch = isTopDown ? 1.48 : .pi / 3.6
        updateCamera()
    }

    @objc private func doubleTapReset() { reset() }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { gestureStart = (yaw, pitch, distance) }
        let translation = gesture.translation(in: gesture.view)
        yaw = gestureStart.yaw - Float(translation.x) * 0.008
        pitch = min(1.48, max(0.18, gestureStart.pitch + Float(translation.y) * 0.006))
        isTopDown = pitch > 1.4
        updateCamera()
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { gestureStart = (yaw, pitch, distance) }
        distance = min(defaultDistance * 3, max(defaultDistance * 0.2, gestureStart.distance / Float(gesture.scale)))
        updateCamera()
    }

    private func updateCamera() {
        let offset = SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
        camera.look(at: target, from: target + offset, relativeTo: nil)
    }
}
