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
    @State private var presentation = MapPresentation.indoor
    @State private var showsPlacement = false
    @State private var selectedFloorID: String?
    @State private var detent = PresentationDetent.height(230)
    @Environment(\.dismiss) private var dismiss

    init(isDemo: Bool = false) {
        let controller = NavigationController(isDemo: isDemo)
        _controller = StateObject(wrappedValue: controller)
        _presentation = State(initialValue: controller.map?.geographicReference == nil ? .indoor : .mapbox)
        _scene = State(initialValue: isDemo ? NavigationDemo.comparisonScene : nil)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                mapContent(bottomInset: sheetInset(geometry))
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) {
                if mode == .map, controller.phase != .noMap {
                    FloorPicker(floors: floors, floorID: floorSelection).padding(.horizontal, 16).padding(.top, 8)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { controller.stop(); dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Navigation view", selection: $mode) {
                        Text("Map").tag(MapMode.map)
                        Text("AR").tag(MapMode.ar)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                if mode == .map {
                    MapToolbarItems(presentation: $presentation, topDown: $topDown,
                                    canPlaceBuilding: controller.map != nil,
                                    onRecenter: { resetID += 1 }, onPlaceBuilding: { showsPlacement = true })
                }
            }
            .sheet(isPresented: $showsNavigation) {
                navigationSheet
                    .presentationDetents([.height(230), .medium], selection: $detent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled)
                    .interactiveDismissDisabled()
                    .fullScreenCover(isPresented: $showsPlacement) {
                        if let map = controller.map {
                            BuildingPlacementView(map: map, currentMapPosition: { controller.placementPosition }) { reference in
                                try controller.setGeographicReference(reference)
                                presentation = .mapbox
                                resetID += 1
                            }
                        }
                    }
            }
            .task {
                controller.start()
                showsNavigation = controller.phase != .noMap
                await recoverSceneIfNeeded()
            }
            .onDisappear { if !showsPlacement { controller.stop() } }
            .onChange(of: controller.phase) { previous, phase in
                if previous == .loading {
                    presentation = controller.map?.geographicReference == nil ? .indoor : .mapbox
                }
                if phase == .noMap { showsNavigation = false }
                if phase == .navigating { selectedFloorID = nil }
            }
            .sensoryFeedback(trigger: controller.phase) { _, phase in
                switch phase {
                case .navigating: .start
                case .arrived: .success
                case .noRoute: .warning
                default: nil
                }
            }
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
                if mode == .ar, controller.phase == .navigating, let route = controller.route {
                    VStack {
                        NextStepBanner(route: route, caption: controller.caption)
                            .padding(.horizontal, 16)
                            .padding(.top, 105)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func standardMap(bottomInset: CGFloat) -> some View {
        NavigationMapSurface(scene: floorContent.scene, map: floorContent.map, presentation: presentation,
                             topDown: topDown, resetID: resetID, bottomInset: bottomInset,
                             groundFloorY: controller.map?.floorY,
                             route: floorContent.isRouteFloor ? controller.route : nil,
                             userPosition: floorContent.isRouteFloor ? controller.position : nil,
                             userHeading: floorContent.isRouteFloor ? controller.heading : nil,
                             destination: floorContent.isRouteFloor ? controller.route?.destination.floorPoint : nil,
                             destinationTitle: floorContent.isRouteFloor ? controller.route?.destination.title : nil) { showsPlacement = true }
    }

    private var navigationSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !floorContent.isRouteFloor {
                    HStack {
                        Text("Route is on \(routeFloorTitle)").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show route") { selectedFloorID = nil; resetID += 1 }
                            .buttonStyle(.glass)
                    }
                }
                switch controller.phase {
                case .noMap: EmptyView()
                case .loading:
                    ProgressView("Loading map…").frame(maxWidth: .infinity, minHeight: 100)
                case .locating:
                    LocatingPanel(startView: controller.startView, isSlow: controller.isRelocalizationSlow,
                                  onStartHere: controller.startFromScanOrigin)
                case .ready:
                    destinationPicker
                    Button(action: controller.navigateToNearest) {
                        Label(controller.isDemo ? "Start demo" : "Go", systemImage: Theme.Symbol.navigate)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                case .routing:
                    ProgressView("Finding a step-free route…").frame(maxWidth: .infinity, minHeight: 120)
                case .navigating:
                    if let route = controller.route {
                        RouteCard(route: route, onEnd: controller.endNavigation)
                        if mode == .map, let caption = controller.caption {
                            Text(caption).font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                case .arrived:
                    ArrivedPanel(destination: controller.route?.destination, onDone: controller.endNavigation)
                case .noRoute:
                    destinationPicker
                    Label("No step-free route from here", systemImage: Theme.symbol(for: .warning))
                        .font(.headline).foregroundStyle(Theme.color(for: .warning))
                    Text("Move to open floor space and try again.").foregroundStyle(.secondary)
                    Button(action: controller.navigateToNearest) {
                        Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                }
            }
            .animation(.smooth, value: controller.phase)
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
                        Text(controller.selectedDestination?.title ?? "Choose destination").font(.panelTitle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                .tint(.primary)
                if let route = controller.route {
                    Text("\(Int(route.length.rounded())) m · Step-free").foregroundStyle(.secondary)
                    if route.isNarrow { Text("Narrow passages").font(.footnote).foregroundStyle(Theme.color(for: .warning)) }
                } else {
                    Text(controller.selectedDestination == nil ? "Nearest elevator or ramp" : "Directions through the building")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if controller.isDemo { Text("Demo").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private func sheetInset(_ geometry: GeometryProxy) -> CGFloat {
        (detent == .medium ? geometry.size.height * 0.5 : 230) + geometry.safeAreaInsets.bottom
    }

    private var floors: [IndoorSceneFloor] { scene.map(IndoorSceneFloors.floors(in:)) ?? [] }
    private var floorSelection: Binding<String?> {
        Binding(get: { floorContent.floor?.id }, set: { selectedFloorID = $0; resetID += 1 })
    }
    private var floorContent: IndoorFloorContent {
        IndoorFloorContent(scene: scene, map: controller.map, selectedFloorID: selectedFloorID)
    }
    private var routeFloorTitle: String {
        floors.min { abs($0.elevation - (controller.map?.floorY ?? 0)) < abs($1.elevation - (controller.map?.floorY ?? 0)) }?.title ?? "another floor"
    }

    @MainActor
    private func recoverSceneIfNeeded() async {
        guard scene == nil, !controller.isDemo else { return }
        let saved = await Task.detached(priority: .userInitiated) {
            (scene: CaptureStore.loadSavedScene(), bundle: CaptureStore.loadSavedBundle())
        }.value
        guard !Task.isCancelled else { return }
        if let existing = saved.scene {
            scene = existing
            return
        }
        guard let bundle = saved.bundle else { return }
        if let url = AppConfig.backendURL {
            do {
                let result = try await BackendClient(baseURL: url).uploadAndProcess(bundle)
                try Task.checkCancellation()
                try CaptureStore.saveScene(result, for: bundle)
                scene = result
                return
            } catch { if Task.isCancelled { return } }
        }
        // A server is optional. Older saved scans can rebuild a room view on the device.
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try LocalSceneBuilder.make(from: bundle)
            }.value
            try Task.checkCancellation()
            try CaptureStore.saveScene(result, for: bundle)
            scene = result
        } catch {
            // The measured floor map and AR directions remain available even without a room model.
        }
    }
}

private struct LocatingPanel: View {
    let startView: UIImage?
    let isSlow: Bool
    let onStartHere: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Finding where you are")
            } icon: {
                Image(systemName: "location.viewfinder").foregroundStyle(Theme.accent).symbolEffect(.pulse)
            }
            .font(.panelTitle)
            Text("Go to where the scan started and slowly look around.").foregroundStyle(.secondary)
            ProgressView()
            if let startView {
                Image(uiImage: startView).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 150).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .accessibilityLabel("Photo of where the scan started")
            }
            if isSlow {
                Text("Stand where the scan started, facing the way the photo does.").font(.footnote)
                Button("Start from here", systemImage: "figure.stand", action: onStartHere).buttonStyle(.glass)
            }
        }
    }
}

/// The next turn in large type, like a turn-by-turn sign, with the last spoken line under it.
private struct NextStepBanner: View {
    let route: Route
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 48)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(distance).font(.metric).contentTransition(.numericText())
                    Text(instruction).font(.title3.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            if let caption {
                Text(caption).font(.subheadline).opacity(0.85).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .glassEffect(.regular.tint(Theme.accent), in: .rect(cornerRadius: Theme.Radius.panel))
        .animation(.smooth, value: distance)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch route.nextManeuver?.turn {
        case .left: "arrow.turn.up.left"
        case .right: "arrow.turn.up.right"
        case .slightLeft: "arrow.up.left"
        case .slightRight: "arrow.up.right"
        case nil: "arrow.up"
        }
    }

    private var distance: String {
        let meters = route.nextManeuver?.distance ?? route.length
        return "\(max(1, Int(meters.rounded()))) m"
    }

    private var instruction: String {
        guard let turn = route.nextManeuver?.turn else { return "to \(route.destination.title)" }
        return turn.phrase.prefix(1).uppercased() + turn.phrase.dropFirst()
    }
}

/// The arrival message, with a bounce and a haptic when it appears.
private struct ArrivedPanel: View {
    let destination: AccessPoint?
    let onDone: () -> Void
    @State private var bounce = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("You’ve arrived")
            } icon: {
                Image(systemName: Theme.symbol(for: .good))
                    .foregroundStyle(Theme.color(for: .good))
                    .symbolEffect(.bounce, value: bounce)
            }
            .font(.panelTitle)
            Text(destination?.title ?? "Destination").foregroundStyle(.secondary)
            if destination?.requiresAssistance == true {
                Label("Needs a staff member to operate", systemImage: Theme.Symbol.needsStaff)
                    .font(.subheadline).foregroundStyle(Theme.color(for: .warning))
            }
            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
        }
        .onAppear { bounce += 1 }
    }
}

private struct RouteCard: View {
    let route: Route
    let onEnd: () -> Void
    /// A relaxed wheelchair pace, for the arrival estimate.
    private static let speed: Float = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                KindBadge(kind: route.destination.kind, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.destination.title).font(.title3.bold())
                    Text(details).font(.subheadline).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("End", action: onEnd)
                    .buttonStyle(.glass)
                    .tint(.red)
                    .controlSize(.large)
            }
            Group {
                if route.destination.requiresAssistance {
                    Label("Needs a staff member to operate", systemImage: Theme.Symbol.needsStaff)
                }
                if route.destination.isTooSteep {
                    Label("Steeper than the ADA allows; it's the only reachable option", systemImage: Theme.symbol(for: .warning))
                }
                if route.isNarrow {
                    Label("Some passages on this route are narrow", systemImage: Theme.Symbol.narrow)
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.color(for: .warning))
        }
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        let minutes = max(1, Int((route.length / Self.speed / 60).rounded(.up)))
        var parts = ["\(minutes) min", "\(Int(route.length.rounded())) m", "step-free"]
        if let slope = route.destination.slopeDegrees {
            parts.append(String(format: "%.1f° slope", slope))
        }
        return parts.joined(separator: " · ")
    }
}
