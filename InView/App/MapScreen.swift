import AccessCore
import SwiftUI

/// The app is one map, like Apple Maps: the scanned floor in 3D the moment it opens, its elevators and ramps
/// pinned on it, and a sheet for directions. AR is another view of the same session, not a separate screen;
/// the camera only turns on when the rider asks for directions or for AR. The demo opens its own copy.
struct MapScreen: View {
    private enum MapMode: String, CaseIterable { case map = "Map", ar = "AR" }
    private enum Cover: String, Identifiable {
        case scan, demo
        var id: String { rawValue }
    }

    let isDemo: Bool
    @StateObject private var controller: NavigationController
    @State private var report: AccessibilityReport?
    /// The processed scan when there is one; otherwise a scene built from the map, so a model always shows.
    @State private var scene: ProcessedScene?
    @State private var mode = MapMode.map
    @State private var topDown = false
    @State private var resetID = 0
    @State private var presentation = MapPresentation.indoor
    @State private var showsPlacement = false
    @State private var showsSettings = false
    @State private var showsReport = false
    @State private var cover: Cover?
    /// A scan may have saved a new map, which replaces this one when the scan closes.
    @State private var reloadsAfterCover = false
    @State private var selectedFloorID: String?
    /// Floors saved by earlier scans, each its own map; the sheet's header switches between them.
    @State private var savedBuildings: [SavedBuilding] = []
    @State private var savedFloor: SavedFloor?
    @State private var floorSwitchError: String?
    @State private var detent = PresentationDetent.height(MapScreen.collapsedHeight)
    @Environment(\.dismiss) private var dismiss

    private static let collapsedHeight: CGFloat = 250

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        let map = isDemo ? nil : MapStore.load()
        let controller = NavigationController(isDemo: isDemo, map: map)
        _controller = StateObject(wrappedValue: controller)
        _report = State(initialValue: isDemo ? nil : MapStore.loadReport())
        _presentation = State(initialValue: controller.map?.geographicReference == nil ? .indoor : .mapbox)
        _scene = State(initialValue: isDemo ? NavigationDemo.comparisonScene : map.flatMap(VenueScene.make))
        _savedBuildings = State(initialValue: isDemo ? [] : MapStore.savedBuildings())
        _savedFloor = State(initialValue: isDemo ? nil : MapStore.currentFloor)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                mapContent(bottomInset: sheetInset(geometry))
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) {
                if mode == .map, controller.map != nil {
                    FloorPicker(floors: floors, floorID: floorSelection).padding(.horizontal, 16).padding(.top, 8)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MapStore.selectionDidChange)) { _ in
                if cover == nil { reload() }
            }
            .alert("Couldn't open this floor", isPresented: Binding(
                get: { floorSwitchError != nil }, set: { if !$0 { floorSwitchError = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(floorSwitchError ?? "") }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: .constant(true)) { sheet }
            .task {
                controller.start()
                await prepareReport()
                await recoverSceneIfNeeded()
            }
            .onDisappear { if !showsPlacement, cover == nil { controller.stop() } }
            .onChange(of: controller.phase) { previous, phase in
                if previous == .loading {
                    presentation = controller.map?.geographicReference == nil ? .indoor : .mapbox
                }
                // Finding the rider needs the camera, so show it.
                if phase == .locating { mode = .ar }
                if phase == .navigating { selectedFloorID = nil }
            }
            .onChange(of: mode) { _, mode in
                if mode == .ar, controller.phase == .browsing { controller.beginGuidance(thenRoute: false) }
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isDemo {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark", role: .close) { controller.stop(); dismiss() }
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("Map a space", systemImage: Theme.Symbol.scan) { present(.scan) }
            }
        }
        if controller.map != nil {
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
    }

    @ViewBuilder
    private func mapContent(bottomInset: CGFloat) -> some View {
        ZStack {
            // Camera tracking stays mounted while the map shows, so switching views keeps the route and position.
            if !controller.isDemo, controller.canGuide {
                ViewContainer(view: controller.arView)
                    .opacity(mode == .ar ? 1 : 0)
                    .allowsHitTesting(mode == .ar)
                    .accessibilityHidden(mode != .ar)
            }
            if controller.map != nil {
                standardMap(bottomInset: bottomInset)
                    .opacity(mode == .map ? 1 : 0)
                    .allowsHitTesting(mode == .map)
                    .accessibilityHidden(mode != .map)
            } else {
                PlanInk.paper
                    .overlay(alignment: .top) {
                        ContentUnavailableView("No floor mapped yet", systemImage: "map",
                                               description: Text("Scan a floor and it appears here in 3D."))
                            .padding(.top, 120)
                    }
            }
            if mode == .ar { arOverlay(bottomInset: bottomInset) }
        }
    }

    /// What sits over the camera: the next turn, and the floor plan as a mini-map that switches back to the map.
    @ViewBuilder
    private func arOverlay(bottomInset: CGFloat) -> some View {
        if controller.isDemo || !controller.canGuide {
            ContentUnavailableView {
                Label(controller.isDemo ? "AR uses your camera" : "AR needs this scan's AR map", systemImage: "camera")
            } description: {
                Text(controller.isDemo
                     ? "Navigate a saved scan on your iPhone to see the route around you."
                     : "Scan this floor again on an iPhone with LiDAR to get directions around you.")
            }
            .padding(.bottom, bottomInset)
            .background(PlanInk.paper)
        } else {
            VStack {
                if controller.phase == .navigating, let route = controller.route {
                    NextStepBanner(route: route, caption: controller.caption)
                        .padding(.horizontal, 16)
                        .padding(.top, 105)
                        .allowsHitTesting(false)
                }
                Spacer()
                if let map = controller.map {
                    Button { mode = .map } label: {
                        MapPreviewView(map: map, route: controller.route, userPosition: controller.position,
                                       userHeading: controller.heading, showsScanStart: false)
                            .frame(width: 132, height: 132)
                            .allowsHitTesting(false)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Radius.control + 4))
                    .accessibilityLabel("Show map")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomInset + 12)
                }
            }
        }
    }

    @ViewBuilder
    private func standardMap(bottomInset: CGFloat) -> some View {
        let destination = controller.route?.destination ?? controller.selectedDestination
        NavigationMapSurface(scene: floorContent.scene, map: floorContent.map, presentation: presentation,
                             topDown: topDown, resetID: resetID, bottomInset: bottomInset,
                             groundFloorY: controller.map?.floorY,
                             route: floorContent.isRouteFloor ? controller.route : nil,
                             userPosition: floorContent.isRouteFloor ? controller.position : nil,
                             userHeading: floorContent.isRouteFloor ? controller.heading : nil,
                             destination: floorContent.isRouteFloor ? destination?.floorPoint : nil,
                             destinationTitle: floorContent.isRouteFloor ? destination?.title : nil,
                             places: floorContent.isRouteFloor ? MapPlace.places(in: controller.map) : [],
                             onSelectPlace: select) { showsPlacement = true }
            .id(savedFloor?.storageID.uuidString ?? "legacy")
    }

    // MARK: Sheet

    private var sheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if controller.map == nil, !isDemo {
                        FirstMapPanel(onScan: { present(.scan) }, onDemo: { present(.demo) })
                    } else {
                        VStack(alignment: .leading, spacing: 18) { guidance }
                        if !isDemo {
                            placesSection
                            if let map = controller.map, let report {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Accessibility").sectionHeading()
                                    ReportSummaryCard(map: map, report: report)
                                }
                            }
                            moreSection
                        }
                    }
                }
                .padding(24)
                .padding(.top, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(Self.collapsedHeight), .medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .interactiveDismissDisabled()
        .fullScreenCover(item: $cover, onDismiss: { if reloadsAfterCover { reloadsAfterCover = false; reload() } }) { cover in
            switch cover {
            case .scan: ScanView()
            case .demo: MapScreen(isDemo: true)
            }
        }
        .fullScreenCover(isPresented: $showsPlacement) {
            if let map = controller.map {
                BuildingPlacementView(map: map, currentMapPosition: { controller.placementPosition }) { reference in
                    try controller.setGeographicReference(reference)
                    presentation = .mapbox
                    resetID += 1
                }
            }
        }
        .sheet(isPresented: $showsSettings) { BackendSettingsView() }
    }

    /// The top of the sheet: where to go and how it's going.
    @ViewBuilder
    private var guidance: some View {
        if !floorContent.isRouteFloor {
            HStack {
                Text("Route is on \(routeFloorTitle)").foregroundStyle(.secondary)
                Spacer()
                Button("Show route") { selectedFloorID = nil; resetID += 1 }
                    .buttonStyle(.glass)
            }
        }
        switch controller.phase {
        case .noMap:
            EmptyView()
        case .loading, .browsing, .ready, .noRoute:
            destinationPicker
            if controller.phase == .noRoute {
                Label("No step-free route from here", systemImage: Theme.symbol(for: .warning))
                    .font(.headline).foregroundStyle(Theme.color(for: .warning))
                Text("Move to open floor space and try again.").foregroundStyle(.secondary)
            }
            Button(action: controller.navigateToNearest) {
                Label(controller.isDemo ? "Start demo" : controller.phase == .noRoute ? "Try again" : "Go",
                      systemImage: controller.phase == .noRoute ? "arrow.clockwise" : Theme.Symbol.navigate)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            .disabled(!controller.isDemo && (!controller.canGuide || controller.phase == .loading))
            if !controller.isDemo, !controller.canGuide, controller.phase == .browsing {
                Text("This map can be explored but not navigated: directions need the AR map saved with a scan on an iPhone with LiDAR.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .locating:
            LocatingPanel(startView: controller.startView, isSlow: controller.isRelocalizationSlow,
                          onStartHere: controller.startFromScanOrigin)
            Button("Cancel", role: .cancel) { controller.endGuidance(); mode = .map }
                .buttonStyle(.glass).controlSize(.large).frame(maxWidth: .infinity)
        case .routing:
            ProgressView("Finding a step-free route…").frame(maxWidth: .infinity, minHeight: 120)
        case .navigating:
            if let route = controller.route {
                RouteCard(route: route, onEnd: endRoute)
                if mode == .map, let caption = controller.caption {
                    Text(caption).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        case .arrived:
            ArrivedPanel(destination: controller.route?.destination, onDone: endRoute)
        }
    }

    private var destinationPicker: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                savedFloorPicker
                Menu {
                    Button("Nearest elevator or ramp") { controller.selectDestination(nil) }
                    ForEach(controller.map?.points ?? []) { point in
                        Button(point.title, systemImage: point.kind.symbolName) { controller.selectDestination(point) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(controller.selectedDestination?.title ?? "Nearest elevator or ramp").font(.panelTitle)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                }
                .tint(.primary)
                if let route = controller.route {
                    Text("\(Int(route.length.rounded())) m · Step-free").foregroundStyle(.secondary)
                    if route.isNarrow { Text("Narrow passages").font(.footnote).foregroundStyle(Theme.color(for: .warning)) }
                } else {
                    Text(floorSummary).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if controller.isDemo { Text("Demo").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    /// Which saved scan is open, above the destination like a venue's name in Maps.
    @ViewBuilder
    private var savedFloorPicker: some View {
        if let savedFloor {
            if savedFloorCount > 1 {
                Menu {
                    ForEach(savedBuildings) { building in
                        Section(building.name) {
                            ForEach(building.floors) { floor in
                                Button(floor.name, systemImage: floor.id == savedFloor.id ? "checkmark" : "building.2") {
                                    selectSavedFloor(floor)
                                }
                            }
                        }
                    }
                } label: { savedFloorLabel(savedFloor, showsChevron: true) }
                .tint(.secondary)
                .accessibilityLabel("Choose saved floor. \(savedFloorTitle(savedFloor))")
            } else {
                savedFloorLabel(savedFloor, showsChevron: false)
                    .accessibilityLabel(savedFloorTitle(savedFloor))
            }
        }
    }

    private func savedFloorLabel(_ floor: SavedFloor, showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "building.2")
            Text(savedFloorTitle(floor))
            if showsChevron { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private var savedFloorCount: Int { savedBuildings.reduce(0) { $0 + $1.floors.count } }

    /// The building is only worth naming when more than one has been scanned.
    private func savedFloorTitle(_ floor: SavedFloor) -> String {
        guard savedBuildings.count > 1,
              let building = savedBuildings.first(where: { $0.id == floor.identity.buildingID }) else { return floor.name }
        return "\(building.name) · \(floor.name)"
    }

    /// Every place on the floor, one tap from being the destination.
    @ViewBuilder
    private var placesSection: some View {
        let points = controller.map?.points ?? []
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("On this floor").sectionHeading()
                VStack(spacing: 0) {
                    ForEach(points) { point in
                        Button { select(MapPlace(point)) } label: {
                            PlaceRow(point: point, isSelected: controller.selectedDestination?.id == point.id)
                        }
                        .buttonStyle(.plain)
                        if point.id != points.last?.id { Divider().padding(.leading, 56) }
                    }
                }
                .card(padding: 6)
            }
        }
    }

    private var moreSection: some View {
        VStack(spacing: 0) {
            SheetRow(title: "Map a space", symbol: Theme.Symbol.scan) { present(.scan) }
            Divider().padding(.leading, 56)
            SheetRow(title: "Try the navigation demo", symbol: Theme.Symbol.demo) { present(.demo) }
            Divider().padding(.leading, 56)
            ShareLink(item: MapStore.mapURL) {
                SheetRowLabel(title: "Export map", symbol: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 56)
            SheetRow(title: "Scan processing", symbol: Theme.Symbol.settings) { showsSettings = true }
        }
        .card(padding: 6)
    }

    private var floorSummary: String {
        let points = controller.map?.points ?? []
        let elevators = points.filter { $0.kind == .elevator }.count
        let ramps = points.filter { $0.kind == .ramp }.count
        let stairs = controller.map?.footprints.filter { $0.kind == .stairs }.count ?? 0
        return ["\(elevators) elevator\(elevators == 1 ? "" : "s")", "\(ramps) ramp\(ramps == 1 ? "" : "s")",
                "\(stairs) stairs"].joined(separator: " · ")
    }

    // MARK: Actions

    private func select(_ place: MapPlace) {
        guard let point = controller.map?.points.first(where: { $0.id == place.id }) else { return }
        controller.selectDestination(point)
    }

    /// Opening another saved floor is like opening another map: guidance stops, then the store publishes
    /// the new selection and `reload` runs from that.
    private func selectSavedFloor(_ floor: SavedFloor) {
        guard floor.id != savedFloor?.id else { return }
        do {
            controller.endGuidance()
            mode = .map
            try MapStore.selectFloor(buildingID: floor.identity.buildingID, floorID: floor.id)
        } catch {
            floorSwitchError = error.localizedDescription
        }
    }

    /// Ending a route turns the camera off and goes back to the map, like ending directions in Maps.
    private func endRoute() {
        controller.endNavigation()
        guard !isDemo else { return }
        controller.endGuidance()
        mode = .map
    }

    /// The scan and the demo run their own camera and map, so this session lets go of the camera first.
    private func present(_ next: Cover) {
        controller.endGuidance()
        mode = .map
        reloadsAfterCover = next == .scan
        cover = next
    }

    /// After a scan, the newly saved map replaces this one.
    private func reload() {
        guard !isDemo else { return }
        let map = MapStore.load()
        report = MapStore.loadReport()
        scene = map.flatMap(VenueScene.make)
        savedBuildings = MapStore.savedBuildings()
        savedFloor = MapStore.currentFloor
        selectedFloorID = nil
        presentation = map?.geographicReference == nil ? .indoor : .mapbox
        resetID += 1
        controller.reload(map: map)
        Task {
            await prepareReport()
            await recoverSceneIfNeeded()
        }
    }

    private func sheetInset(_ geometry: GeometryProxy) -> CGFloat {
        (detent == .height(Self.collapsedHeight) ? Self.collapsedHeight : geometry.size.height * 0.5) + geometry.safeAreaInsets.bottom
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

    /// A map saved without its report (one shared from another phone, say) gets one checked here.
    @MainActor
    private func prepareReport() async {
        guard !isDemo, report == nil, let map = controller.map else { return }
        report = await Task.detached(priority: .utility) { AccessibilityReport(map: map) }.value
    }

    /// Prefers the scan's processed room over the scene built from the map, when there is one.
    @MainActor
    private func recoverSceneIfNeeded() async {
        guard !isDemo, controller.map != nil else { return }
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
            // The scene built from the map stays.
        }
    }
}

/// The sheet before anything is mapped: how mapping works, and the way in.
private struct FirstMapPanel: View {
    let onScan: () -> Void
    let onDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Map your first floor").font(.panelTitle)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Start at the entrance and tap Map a space.")
                step(2, "Walk the floor. InView pins elevators, ramps and stairs as it sees them.")
                step(3, "Review and save, and anyone can navigate it.")
            }
            Button(action: onScan) {
                Label("Map a space", systemImage: Theme.Symbol.scan).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            Button(action: onDemo) {
                Label("Try the navigation demo", systemImage: Theme.Symbol.demo).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).controlSize(.large)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// One place in the sheet's list, with its badge and what's known about it.
private struct PlaceRow: View {
    let point: AccessPoint
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: point.kind, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title).font(.body.weight(.medium))
                Text(details).font(.caption).foregroundStyle(point.isTooSteep ? Theme.color(for: .warning) : .secondary)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark").font(.headline).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var details: String {
        var parts: [String] = []
        if let slope = point.slopeDegrees {
            parts.append(String(format: point.isTooSteep ? "%.1f° slope · too steep" : "%.1f° slope", slope))
        }
        if point.requiresAssistance {
            parts.append("Needs staff to operate")
        } else if point.kind == .elevator {
            parts.append("Usable on your own")
        }
        return parts.isEmpty ? point.kind.title : parts.joined(separator: " · ")
    }
}

private struct SheetRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { SheetRowLabel(title: title, symbol: symbol) }
            .buttonStyle(.plain)
    }
}

private struct SheetRowLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.12), in: Circle())
            Text(title).font(.body)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(.rect)
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
