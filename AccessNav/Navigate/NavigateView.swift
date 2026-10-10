import AccessCore
import SwiftUI

/// The map and camera are two views of the same navigation session.
struct NavigateView: View {
    private enum MapMode: String, CaseIterable { case map = "Map", ar = "AR" }
    @StateObject private var controller: NavigationController
    @State private var scene: ProcessedScene?
    @State private var mode = MapMode.map
    @State private var topDown = false
    @State private var resetID = 0
    @State private var showsNavigation = false
    @State private var detent = PresentationDetent.height(230)
    @Environment(\.dismiss) private var dismiss

    init(isDemo: Bool = false) {
        _controller = StateObject(wrappedValue: NavigationController(isDemo: isDemo))
        _scene = State(initialValue: isDemo ? NavigationDemo.scene : CaptureStore.loadSavedScene())
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                mapContent(bottomInset: sheetInset(geometry))
                    .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { controller.stop(); dismiss() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .principal) {
                    Picker("Navigation view", selection: $mode) {
                        Text("Map").tag(MapMode.map)
                        Text("AR").tag(MapMode.ar)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if mode == .map {
                        Button("Overview", systemImage: "arrow.up.left.and.arrow.down.right") { resetID += 1 }
                            .labelStyle(.iconOnly)
                        Button(topDown ? "3D" : "2D") { topDown.toggle() }
                            .accessibilityLabel(topDown ? "Show 3D" : "Show 2D")
                    }
                }
            }
            .sheet(isPresented: $showsNavigation) {
                navigationSheet
                    .presentationDetents([.height(230), .medium], selection: $detent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled)
                    .interactiveDismissDisabled()
            }
            .task {
                controller.start()
                if controller.phase != .noMap { showsNavigation = true }
                await recoverSceneIfNeeded()
            }
            .onDisappear { controller.stop() }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private func mapContent(bottomInset: CGFloat) -> some View {
        if controller.phase == .noMap {
            ContentUnavailableView("No map yet", systemImage: "map", description: Text("A volunteer needs to scan this floor first."))
        } else {
            ZStack {
                // Keep camera tracking mounted when the overview is visible. Switching views
                // changes presentation only, so relocalization and the route stay continuous.
                if !controller.isDemo {
                    ViewContainer(view: controller.arView)
                        .opacity(mode == .ar ? 1 : 0)
                        .allowsHitTesting(mode == .ar)
                        .accessibilityHidden(mode != .ar)
                }
                standardMap(bottomInset: bottomInset)
                    .opacity(mode == .map ? 1 : 0)
                    .allowsHitTesting(mode == .map)
                    .accessibilityHidden(mode != .map)
                if controller.isDemo && mode == .ar {
                    ContentUnavailableView("AR uses your camera", systemImage: "camera", description: Text("Navigate a saved scan on your iPhone to see the route around you."))
                }
            }
        }
    }

    @ViewBuilder
    private func standardMap(bottomInset: CGFloat) -> some View {
        if let scene {
            RoomMapCanvas(scene: scene, selectedObjectID: .constant(nil), showsLabels: false,
                          topDown: topDown, resetID: resetID, viewportBottomInset: bottomInset,
                          routePoints: controller.route?.waypoints ?? [], userPosition: controller.position,
                          userHeading: controller.heading, floorY: controller.map?.floorY ?? 0,
                          destination: controller.route?.destination.floorPoint,
                          destinationTitle: controller.route?.destination.title,
                          isNavigating: true)
        } else if let map = controller.map {
            MapPreviewView(map: map, route: controller.route, userPosition: controller.position,
                           userHeading: controller.heading, showsScanStart: false)
                .padding(.bottom, bottomInset)
                .background(Color(.systemGroupedBackground))
        }
    }

    private var navigationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch controller.phase {
                case .noMap: EmptyView()
                case .locating:
                    LocatingPanel(startView: controller.startView, isSlow: controller.isRelocalizationSlow,
                                  onStartHere: controller.startFromScanOrigin)
                case .ready:
                    destinationPicker
                    Button(action: controller.navigateToNearest) {
                        Label(controller.isDemo ? "Start demo" : "Go", systemImage: "arrow.turn.up.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                case .routing:
                    ProgressView("Finding a step-free route…").frame(maxWidth: .infinity, minHeight: 120)
                case .navigating:
                    routeHeading
                    HStack {
                        Label("Follow the route", systemImage: "arrow.up")
                            .font(.headline)
                        Spacer()
                        Button("End", role: .destructive, action: controller.endNavigation)
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                case .arrived:
                    Label("You’ve arrived", systemImage: "checkmark.circle.fill")
                        .font(.title2.bold()).foregroundStyle(.green)
                    Text(controller.route?.destination.title ?? "Destination").foregroundStyle(.secondary)
                    Button("Done", action: controller.endNavigation)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                case .noRoute:
                    destinationPicker
                    Label("No step-free route from here", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text("Move to open floor space and try again.").foregroundStyle(.secondary)
                    Button("Try again", action: controller.navigateToNearest)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(24)
            .padding(.top, 6)
        }
    }

    private var destinationPicker: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Menu {
                    Button("Nearest elevator or ramp") { controller.selectDestination(nil) }
                    ForEach(controller.map?.points ?? []) { point in
                        Button(point.title, systemImage: point.kind.symbolName) { controller.selectDestination(point) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(controller.selectedDestination?.title ?? "Choose destination").font(.title2.bold())
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                .tint(.primary)
                if let route = controller.route {
                    Text("\(Int(route.length.rounded())) m · Step-free").foregroundStyle(.secondary)
                    if route.isNarrow { Text("Narrow passages").font(.footnote).foregroundStyle(.orange) }
                } else {
                    Text(controller.selectedDestination == nil ? "Nearest elevator or ramp" : "Directions through the building")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if controller.isDemo { Text("Demo").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private var routeHeading: some View {
        HStack(alignment: .top, spacing: 12) {
            if let route = controller.route {
                Image(systemName: route.destination.kind.symbolName)
                    .font(.title2).foregroundStyle(.blue)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.destination.title).font(.title2.bold())
                    Text("\(Int(route.length.rounded())) m · Step-free").foregroundStyle(.secondary)
                    if route.isNarrow {
                        Label("Narrow passages", systemImage: "arrow.left.and.right")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where would you like to go?").font(.title3.bold())
                    Text("Nearest elevator or ramp").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if controller.isDemo { Text("Demo").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private func sheetInset(_ geometry: GeometryProxy) -> CGFloat {
        (detent == .medium ? geometry.size.height * 0.5 : 230) + geometry.safeAreaInsets.bottom
    }

    @MainActor
    private func recoverSceneIfNeeded() async {
        guard scene == nil, !controller.isDemo, let bundle = CaptureStore.loadSavedBundle(),
              let url = AppConfig.backendURL else { return }
        do {
            let result = try await BackendClient(baseURL: url).uploadAndProcess(bundle)
            try Task.checkCancellation()
            try CaptureStore.saveScene(result, for: bundle)
            scene = result
        } catch {
            // Navigation stays available from the measured map and AR world map offline.
        }
    }
}

private struct LocatingPanel: View {
    let startView: UIImage?
    let isSlow: Bool
    let onStartHere: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finding where you are").font(.title2.bold())
            Text("Go to where the scan started and slowly look around.").foregroundStyle(.secondary)
            ProgressView()
            if let startView {
                Image(uiImage: startView).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 150).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Photo of where the scan started")
            }
            if isSlow {
                Text("Stand where the scan started, facing the way the photo does.").font(.footnote)
                Button("Start from here", action: onStartHere).buttonStyle(.bordered)
            }
        }
    }
}
