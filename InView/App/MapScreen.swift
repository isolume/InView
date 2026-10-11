import AccessCore
import SwiftUI
import simd

/// One map, with search, place details and directions sharing the same sheet.
struct MapScreen: View {
    private enum Panel { case explore, place, directions, chooseStart, placement }
    /// Where directions begin: the person's live position, a place on the floor, or a point tapped on the map.
    private enum RouteStart: Equatable {
        case myLocation
        case place(UUID)
        case mapPoint(SIMD2<Float>)
    }
    private enum MapStyle: String { case model, scan }
    private enum Modal: String, Identifiable {
        case account, contribute, submissions, building, savedMaps, settings, arUnavailable, buildingDirections
        var id: String { rawValue }
    }
    private enum Cover: String, Identifiable {
        case scan, demo
        var id: String { rawValue }
    }

    let isDemo: Bool
    @StateObject private var controller: NavigationController
    @StateObject private var library = BuildingMapLibrary()
    @StateObject private var live = LivePlaceSearch()
    @StateObject private var assistant = VoiceAssistant()
    @ObservedObject private var account = AccountSession.shared
    @State private var scene: ProcessedScene?
    @State private var detailScene: ProcessedScene?
    @State private var showsScanDetail = false
    @State private var isPreparedScene = false
    @State private var sceneGeneration = 0
    @State private var mapStyle = MapStyle.model
    @State private var illustrationState = IllustrationLayerState.loading
    @AppStorage("studentCenter.model.offsetAcross") private var modelAcross = 0.0
    @AppStorage("studentCenter.model.offsetAlong") private var modelAlong = 0.0
    @AppStorage("studentCenter.model.rotation") private var modelRotation = 0.0
    @AppStorage("studentCenter.model.scale") private var modelScale = 1.0
    @AppStorage("navigation.routePreference") private var savedRoutePreference = RoutePreference.stepFree.rawValue
    /// Find the person as soon as a map scanned on this device opens, so directions can start at once.
    @AppStorage("navigation.findsMeAutomatically") private var findsMeAutomatically = true
    @State private var demoRoutePreference = RoutePreference.stepFree
    @State private var sourceLevel = 2
    @State private var displayedPublishedVersion: UInt64?
    @State private var selectedLevel = 2
    @State private var localFloor: SavedFloor?
    @State private var panel = Panel.explore
    @State private var modal: Modal?
    @State private var cover: Cover?
    @State private var query = ""
    @State private var topDown = false
    @State private var resetID = 0
    @State private var showsAR = false
    /// The AR camera reads signs and tags the doors they label.
    @State private var readsSigns = false
    @State private var detent = PresentationDetent.height(240)
    @State private var showsMainSheet = false
    @State private var previewRoute: Route?
    @State private var previewStart: SIMD2<Float>?
    @State private var routeStart: RouteStart?
    @State private var swapTurns = 0
    /// Shown for a moment when the camera finds the person.
    @State private var showsFoundYou = false
    @State private var isFindingRoute = false
    @State private var routeMessage: String?
    @State private var routeCheck: ServerRouteCheck?
    @State private var routeGeneration = 0
    @State private var floorError: String?
    @State private var selectedModelPlace: AccessPoint?
    /// A place the assistant was asked to show, opened once a map style change settles.
    @State private var pendingAssistantPlace: UUID?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        let map = isDemo ? NavigationDemo.map : StudentCenterCatalog.map()
        _controller = StateObject(wrappedValue: NavigationController(isDemo: isDemo, map: map, usesBundledMap: !isDemo))
        _scene = State(initialValue: isDemo ? NavigationDemo.scene : StudentCenterCatalog.scene())
        _isPreparedScene = State(initialValue: !isDemo && StudentCenterCatalog.scene() != nil)
        _sourceLevel = State(initialValue: isDemo ? 1 : 2)
        _selectedLevel = State(initialValue: isDemo ? 1 : 2)
    }

    private var hasMap: Bool { controller.map != nil && selectedLevel == sourceLevel }
    private var hasVisualFloor: Bool { hasMap || modelAvailable }
    private var hasScanDetail: Bool {
        guard hasMap, let scene, let detailScene,
              detailScene.sourceScanID == scene.sourceScanID, detailScene.mapID == scene.mapID,
              detailScene.floorID == scene.floorID else { return false }
        return detailScene.meshes.contains { $0.sourceID == ReconstructedMesh.sourceID }
    }
    private var title: String { isDemo ? "Navigation demo" : localFloor == nil ? StudentCenterCatalog.buildingName : MapStore.currentBuilding?.name ?? "Saved building" }
    /// A route from a chosen start is a preview; from "My location" it's the live session's route.
    private var activeRoute: Route? { previewStart != nil ? previewRoute : controller.route }
    /// Model places may be endpoints where the open map has matching measured coverage.
    private var routablePlaces: [AccessPoint] {
        guard hasMap else { return [] }
        return (controller.map?.points ?? []) + livePins + (modelHasMatchingMap ? registeredModelPoints : [])
    }
    private var canUseMyLocation: Bool { isDemo || controller.canGuide }
    private var routePreference: RoutePreference {
        isDemo ? demoRoutePreference : RoutePreference(rawValue: savedRoutePreference) ?? .stepFree
    }
    private var routePreferenceSelection: Binding<RoutePreference> {
        Binding(get: { routePreference }, set: {
            if isDemo { demoRoutePreference = $0 } else { savedRoutePreference = $0.rawValue }
        })
    }
    private var modelAvailable: Bool {
        !isDemo && localFloor == nil && StudentCenterCatalog.hasEstimatedModel(on: selectedLevel)
            && registrationMap.flatMap { StudentCenterModelAlignment.transform(for: $0, floor: selectedLevel) } != nil
    }
    private var showsModel: Bool { modelAvailable && mapStyle == .model }
    private var modelHasMatchingMap: Bool {
        selectedLevel == 2 && hasMap && modelAvailable
            && controller.map.flatMap(StudentCenterLocalization.mapFromWorld) != nil
    }
    private var selectedDestinationIsModelPlace: Bool {
        guard let destination = controller.selectedDestination else { return false }
        return StudentCenterCatalog.modelLandmarks(for: selectedLevel).contains { $0.id == destination.id }
    }
    private var registrationMap: VenueMap? {
        // The exported asset has a fixed registration. Edited place pins must not move the model.
        StudentCenterCatalog.map()
    }
    private var modelTransform: simd_float4x4? {
        guard modelAvailable, let map = registrationMap,
              let base = StudentCenterModelAlignment.transform(for: map, floor: selectedLevel),
              let landmark = map.points.first(where: { $0.id == StudentCenterModelAlignment.firstElevatorID }) else { return nil }
        // Floor 2 is reconstructed in the scan frame. Keep its geometry, pins,
        // start taps and routes aligned even if an older model had saved offsets.
        if selectedLevel == 2 { return base }
        let pivot = landmark.position
        let angle = Float(bounded(modelRotation, in: -90...90)) * .pi / 180
        let scale = Float(bounded(modelScale, in: 0.5...1.5))
        let c = cos(angle) * scale, s = sin(angle) * scale
        let rotation = simd_float4x4(columns: (
            SIMD4(c, 0, s, 0), SIMD4(0, scale, 0, 0), SIMD4(-s, 0, c, 0), SIMD4(0, 0, 0, 1)))
        func translation(_ point: SIMD3<Float>) -> simd_float4x4 {
            var value = matrix_identity_float4x4
            value.columns.3 = SIMD4(point, 1)
            return value
        }
        let offset = SIMD3(Float(bounded(modelAcross, in: -15...15)), 0, Float(bounded(modelAlong, in: -15...15)))
        return translation(pivot + offset) * rotation * translation(-pivot) * base
    }

    private var modelFloorY: Float {
        guard let transform = modelTransform else { return 0 }
        return (transform * SIMD4(0, StudentCenterCatalog.modelFloorY(for: selectedLevel) ?? 0, 0, 1)).y
    }

    /// Floor 2 landmarks can be route destinations; they never add walkable coverage.
    /// Floor 3 landmarks remain display-only until that floor has its own route map.
    private var modelPoints: [AccessPoint] { showsModel ? registeredModelPoints : [] }

    private var registeredModelPoints: [AccessPoint] {
        guard modelAvailable, let transform = modelTransform else { return [] }
        return StudentCenterCatalog.modelLandmarks(for: selectedLevel).compactMap { landmark in
            if hasMap, landmark.title == "Lifts", controller.map?.points.contains(where: { $0.kind == .elevator }) == true { return nil }
            let ground = SIMD4(landmark.position.x, StudentCenterCatalog.modelFloorY(for: selectedLevel) ?? 0, landmark.position.z, 1)
            let position = transform * ground
            return AccessPoint(id: landmark.id, kind: landmark.title == "Lifts" ? .elevator : .destination,
                name: landmark.title, position: SIMD3(position.x, position.y, position.z), source: .manual, confidence: 0.5)
        }
    }

    private var displayPoints: [AccessPoint] { (hasMap ? controller.map?.points ?? [] : []) + livePins + modelPoints }

    /// The server scan behind a saved floor; published and example maps have none to search.
    private var liveScanID: String? { isDemo ? nil : localFloor?.captureID }
    /// Live places from the scan server, pinned at the spot the scan measured them on this floor.
    private var livePins: [AccessPoint] { hasMap && liveScanID != nil ? live.pins : [] }
    private var liveAnswersQuery: Bool { live.answeredQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Search from the person when tracked, else a chosen start, else the scan's origin, which is
    /// where the walk began and so lies on the mapped paths.
    private var liveOrigin: SIMD3<Float> {
        let point = (controller.isPositionReliable ? controller.position : nil) ?? previewStart ?? .zero
        return SIMD3(point.x, controller.map?.floorY ?? 0, point.y)
    }
    private var liveTrigger: LiveSearchTrigger {
        LiveSearchTrigger(scanID: hasMap ? liveScanID : nil, origin: liveOrigin, query: query,
                          pointCount: controller.map?.points.count ?? 0)
    }
    /// Matches on other floors are listed with how to get there, not pinned on this floor.
    private var otherFloorResults: [NearbyPlace] {
        guard hasMap, liveScanID != nil, liveAnswersQuery else { return [] }
        return Array(live.results.filter { $0.levelDelta != 0 }.prefix(5))
    }

    /// Left, right or ahead from where the person stands now, when their position is known.
    private func liveDirection(_ result: NearbyPlace) -> String? {
        guard controller.isPositionReliable, let position = controller.position else { return nil }
        return result.relativeDirection(from: position, headingRadians: controller.heading)
    }

    private func bounded(_ value: Double, in range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
    }
    private var points: [AccessPoint] {
        guard hasVisualFloor else { return [] }
        let local = (hasMap ? controller.map?.points ?? [] : []) + modelPoints
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = text.isEmpty ? local : local.filter { $0.matches(query: text) }
        // The server already matched live places against names, sign text and everyday words.
        let served = liveAnswersQuery ? livePins : []
        return matched + served.filter { pin in !matched.contains { $0.id == pin.id } }
    }

    /// Wide windows, like a full-screen iPad, keep the panel beside the map as Maps does; narrow ones use a sheet.
    private var usesSidePanel: Bool { sizeClass == .regular }

    var body: some View {
        presentingModals(NavigationStack {
            GeometryReader { geometry in
                let sideInset = usesSidePanel ? sidePanelWidth(geometry) + 32 : 0
                ZStack(alignment: .topLeading) {
                    mapSurface(bottomInset: mapInset(geometry), leadingInset: sideInset)
                        .ignoresSafeArea()
                    floatingControls(leadingInset: usesSidePanel ? sideInset : 16)
                    if usesSidePanel { sidePanel(geometry) }
                    if showsFoundYou {
                        FoundYouBadge()
                            .frame(maxWidth: .infinity)
                            .padding(.leading, usesSidePanel ? sideInset : 0)
                            .padding(.top, 70)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }, when: usesSidePanel)
        .sheet(isPresented: $showsMainSheet) { mainSheet }
        .background(Color(.systemGroupedBackground))
        .preferredColorScheme(.light)
        .onAppear {
            controller.setRoutePreference(routePreference)
            controller.locatesAutomatically = findsMeAutomatically && !isDemo
            showsMainSheet = !usesSidePanel
        }
        .onChange(of: findsMeAutomatically) { _, automatic in
            controller.locatesAutomatically = automatic && !isDemo
            if automatic, !isDemo, controller.canGuide, controller.phase == .browsing { controller.findRider() }
        }
        // Scanning and the demo need the camera to themselves; finding the person resumes afterwards.
        .onChange(of: modal) { old, new in
            if new == .contribute { controller.endGuidance() }
            else if old == .contribute, findsMeAutomatically, !isDemo, controller.canGuide { controller.findRider() }
        }
        .onChange(of: cover) { _, new in
            if new != nil { controller.endGuidance() }
            else if findsMeAutomatically, !isDemo, controller.canGuide { controller.findRider() }
        }
        .onChange(of: usesSidePanel) { _, side in showsMainSheet = !side && !readsSigns }
        // The sign reader needs the whole camera; the sheet returns when it closes.
        .onChange(of: readsSigns) { _, reading in showsMainSheet = !usesSidePanel && !reading }
        .onChange(of: showsAR) { _, shown in if !shown { readsSigns = false } }
        .onChange(of: assistant.phase) { _, phase in
            if phase == .answered, assistant.place != nil { showAssistantPlace() }
        }
        .task {
            controller.start()
            if !isDemo {
                if let release = acceptedRelease(for: 2) { openRelease(release) }
                await library.refresh()
                if selectedLevel == 2, panel == .explore, query.isEmpty,
                   let release = acceptedRelease(for: 2), release.version != displayedPublishedVersion,
                   controller.phase == .browsing || controller.phase == .loading {
                    openRelease(release)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MapStore.selectionDidChange)) { _ in
            guard cover == nil else { return }
            if let floor = MapStore.currentFloor {
                if floor != localFloor { openSavedFloor(floor) }
            } else if localFloor != nil {
                // The open saved map was deleted.
                localFloor = nil
                switchFloor(StudentCenterCatalog.floorLevel)
            }
        }
        .onDisappear { controller.stop(); assistant.dismiss() }
        .onChange(of: mapStyle) { _, _ in
            if selectedModelPlace != nil { closeDestination() }
            resetID += 1
            if let id = pendingAssistantPlace { pendingAssistantPlace = nil; revealPlace(id) }
        }
        .onChange(of: routePreference) { _, _ in routePreferenceChanged() }
        .onChange(of: liveTrigger, initial: true) { _, trigger in
            live.update(scanID: trigger.scanID, origin: trigger.origin, query: trigger.query,
                        existing: controller.map?.points ?? [])
        }
        .onChange(of: controller.phase) { old, new in
            guard old == .locating, controller.isLocated else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { showsFoundYou = true }
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeOut(duration: 0.3)) { showsFoundYou = false }
            }
        }
        .onChange(of: controller.phase) { _, phase in
            // Finding the person happens behind the map; AR only opens when they ask for it.
            if phase == .navigating || phase == .arrived { panel = .directions; detent = .height(440) }
        }
        .sensoryFeedback(trigger: controller.phase) { _, phase in
            switch phase {
            case .arrived: .success
            case .noRoute: .warning
            default: nil
            }
        }
    }

    @ViewBuilder private func mapSurface(bottomInset: CGFloat, leadingInset: CGFloat) -> some View {
        if showsAR, controller.canGuide {
            ViewContainer(view: controller.arView)
                .overlay {
                    if readsSigns, controller.isPositionReliable {
                        SignReaderOverlay(reader: controller.signReader, session: controller.arView.session,
                                          preview: signPreview, onAdd: tagSign, onShowOnMap: showTaggedPlace,
                                          onClose: { readsSigns = false })
                    }
                }
                .overlay(alignment: .top) {
                    if !controller.isPositionReliable, controller.phase != .locating {
                        Text("Position lost · Look around to reconnect")
                            .font(.subheadline.weight(.medium))
                            .padding(12).glassEffect(.regular, in: Capsule())
                            .padding(.top, 85)
                    } else if !readsSigns, let route = controller.route, controller.phase == .navigating {
                        NextStepBanner(route: route, caption: controller.caption).padding(.horizontal, 16).padding(.top, 85)
                    }
                }
        } else if hasVisualFloor {
            NavigationMapSurface(scene: hasMap ? scene : StudentCenterCatalog.estimatedScene(for: selectedLevel),
                map: hasMap ? controller.map : nil, presentation: .indoor,
                topDown: topDown, resetID: resetID, bottomInset: bottomInset, leadingInset: leadingInset,
                groundFloorY: hasMap ? controller.map?.floorY : modelFloorY,
                route: hasMap ? activeRoute : nil,
                userPosition: hasMap ? previewStart ?? (controller.isPositionReliable ? controller.position : nil) : nil,
                userHeading: hasMap && previewStart == nil && controller.isPositionReliable ? controller.heading : nil,
                destination: hasMap ? controller.selectedDestination?.floorPoint : nil,
                destinationTitle: hasMap ? controller.selectedDestination?.title : nil,
                places: displayPoints.map(MapPlace.init),
                onSelectPlace: selectPlace,
                onSelectFloorPoint: hasMap && panel == .chooseStart ? { routeStart = .mapPoint($0); chooseStart($0) } : nil,
                initialYaw: isDemo || localFloor != nil ? nil : showsModel ? 3.15 : 1.40,
                isPreparedScene: !hasMap || isPreparedScene,
                illustrationURL: modelAvailable ? StudentCenterCatalog.illustrationURL(for: selectedLevel) : nil,
                mapFromIllustration: modelTransform,
                showsIllustration: showsModel,
                showsScanOutline: false,
                onIllustrationState: { illustrationState = $0 },
                detailedScan: hasMap && !showsModel && showsScanDetail,
                detailScene: hasMap ? detailScene : nil,
                onPlaceBuilding: {})
                .overlay {
                    if showsModel, illustrationState == .loading {
                        ProgressView("Opening map…").padding(16)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.bottom, bottomInset).padding(.leading, leadingInset)
                    } else if showsModel, illustrationState == .failed, !hasMap {
                        ContentUnavailableView("3D map unavailable", systemImage: "cube",
                            description: Text("Choose another floor to explore."))
                            .padding(.bottom, bottomInset).padding(.leading, leadingInset)
                    }
                }
        } else {
            Color(red: 0.92, green: 0.93, blue: 0.91)
                .overlay {
                    ContentUnavailableView("No map for Floor \(selectedLevel)", systemImage: "map",
                        description: Text("This floor hasn’t been mapped yet."))
                        .padding(.bottom, bottomInset).padding(.leading, leadingInset)
                }
        }
    }

    private func floatingControls(leadingInset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: enterAR) {
                Label(showsAR ? "Map" : "View in AR", systemImage: showsAR ? "map.fill" : "viewfinder")
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 15).frame(height: 46)
            }
            .disabled(controller.phase == .loading)
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityLabel(showsAR ? "Return to map" : "Enter AR mode")
            if showsAR, !readsSigns, controller.canGuide, !isDemo {
                Button { readsSigns = true } label: {
                    Label("Read signs", systemImage: "text.viewfinder")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 15).frame(height: 46)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: Capsule())
                .disabled(!controller.isPositionReliable)
                .accessibilityHint("Point the camera at a room number or exit sign to label its door on the map")
            }
            Spacer(minLength: 0)
            cameraPreview
            GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                if !isDemo {
                    VStack(spacing: 2) {
                        ForEach([3, 2, 1], id: \.self) { level in
                            Button { switchFloor(level) } label: {
                                Text("\(level)").font(.system(.body, design: .rounded).weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(selectedLevel == level ? Color.white : .primary)
                                    .background(selectedLevel == level ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Floor \(level)\(mapAvailable(on: level) ? "" : ", no map")")
                            .accessibilityAddTraits(selectedLevel == level ? .isSelected : [])
                        }
                    }
                    .padding(4).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 17))
                    .frame(width: 52)
                    .animation(.smooth, value: selectedLevel)
                    .sensoryFeedback(.selection, trigger: selectedLevel)
                }
                if hasVisualFloor, !showsAR {
                    if modelAvailable || hasScanDetail {
                        Menu {
                            if modelAvailable {
                                Picker("Map appearance", selection: $mapStyle) {
                                    Text("3D model").tag(MapStyle.model)
                                    if hasMap { Text("Floor scan").tag(MapStyle.scan) }
                                }
                            }
                            if hasScanDetail, !showsModel {
                                Toggle("Scan detail", isOn: $showsScanDetail)
                            }
                            if showsModel, selectedLevel != 2 {
                                Button("Adjust placement", systemImage: "slider.horizontal.3") {
                                    closeDestination(); mapStyle = .model
                                    panel = .placement; detent = .height(440)
                                }
                                Text("Estimated model")
                            }
                        } label: {
                            Image(systemName: "square.3.layers.3d").font(.system(size: 19, weight: .medium))
                                .frame(width: 52, height: 48)
                        }
                        .foregroundStyle(.primary)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 17))
                        .accessibilityLabel("Map appearance")
                    }
                    VStack(spacing: 0) {
                        Button { topDown.toggle() } label: {
                            Text(topDown ? "3D" : "2D").font(.subheadline.weight(.semibold)).frame(width: 52, height: 48)
                        }
                        .accessibilityLabel(topDown ? "Show 3D map" : "Show 2D map")
                        Divider().padding(.horizontal, 10)
                        Button { resetID += 1 } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 17, weight: .medium)).frame(width: 52, height: 48)
                        }
                        .accessibilityLabel("Fit floor map")
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 52)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 17))
                }
                if !isDemo, hasMap, !showsAR {
                    Button(action: locateMe) {
                        Image(systemName: locationSymbol).font(.system(size: 19, weight: .medium))
                            .symbolEffect(.pulse, isActive: controller.phase == .locating)
                            .frame(width: 52, height: 48)
                    }
                    .foregroundStyle(controller.isLocated ? Color.white : .primary)
                    .glassEffect(controller.isLocated ? .regular.tint(Theme.accent).interactive() : .regular.interactive(),
                                 in: RoundedRectangle(cornerRadius: 17))
                    .accessibilityLabel(locationLabel)
                }
            }
            }
        }
        .padding(.leading, leadingInset).padding(.trailing, 16).padding(.top, 10)
    }

    private var locationSymbol: String {
        if controller.isLocated { return controller.isPositionReliable ? "location.fill" : "location.slash" }
        return "location"
    }

    private var locationLabel: String {
        if controller.phase == .locating { return "Finding your location. Double tap to stop." }
        if controller.isLocated { return "Your location. Double tap to fit it on the map." }
        return "Show my location"
    }

    /// While the camera looks for the person, a small preview shows what it sees; the map stays on screen.
    @ViewBuilder private var cameraPreview: some View {
        if !showsAR, !isDemo, controller.canGuide,
           controller.phase == .locating || (controller.isLocated && !controller.isPositionReliable) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let image = controller.cameraPreview {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.black.overlay { ProgressView().tint(.white) }
                    }
                }
                .frame(height: 100).frame(maxWidth: .infinity)
                .overlay { RadarPulse() }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
                Text(controller.locatingHint ?? (controller.phase == .locating
                     ? "Hold up your \(UIDevice.current.model) and look around slowly"
                     : "Position lost · Look around to reconnect"))
                    .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(7).frame(width: 150)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func sidePanelWidth(_ geometry: GeometryProxy) -> CGFloat {
        min(400, max(320, geometry.size.width * 0.38))
    }

    /// The iPad panel: as tall as its content, scrolling only when it would run past the window.
    private func sidePanel(_ geometry: GeometryProxy) -> some View {
        ViewThatFits(in: .vertical) {
            panelContent
            ScrollView { panelContent }.scrollDismissesKeyboard(.interactively)
        }
        .frame(width: sidePanelWidth(geometry))
        .frame(maxHeight: max(200, geometry.size.height - 20), alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .padding(.leading, 16).padding(.top, 10)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if panel == .explore { explorePanel }
            else if panel == .placement { placementPanel }
            else { destinationPanel }
        }
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 28)
    }

    private var mainSheet: some View {
        presentingModals(ScrollView { panelContent }
            .scrollDismissesKeyboard(.interactively)
            .presentationDetents([.height(240), .height(440), .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackgroundInteraction(.enabled(upThrough: .height(440)))
            .interactiveDismissDisabled(), when: !usesSidePanel)
    }

    /// Sheets open from the topmost view: the search sheet on iPhone, the screen itself beside the iPad panel.
    private func presentingModals<Content: View>(_ content: Content, when active: Bool) -> some View {
        content
        .sheet(item: active ? $modal : .constant(nil)) { modal in
            switch modal {
            case .account: AccountExperienceView()
            case .contribute: ContributeExperienceView()
            case .submissions: MySubmissionsView()
            case .settings: BackendSettingsView()
            case .building:
                if localFloor != nil, let building = MapStore.currentBuilding {
                    SavedMapsView(building: building.id, openFloorID: localFloor?.id, onOpenBuiltIn: nil, onOpen: selectSavedFloor)
                } else {
                    BuildingDetailsSheet(library: library, releaseForFloor: acceptedRelease, onShowFloor: switchFloor)
                }
            case .savedMaps:
                SavedMapsView(openFloorID: localFloor?.id,
                              onOpenBuiltIn: localFloor == nil ? nil : { localFloor = nil; switchFloor(2) },
                              onOpen: selectSavedFloor)
            case .arUnavailable: arUnavailableSheet
            case .buildingDirections:
                BuildingDirectionsView(venueID: "student-center-east", graphID: "student-center-east",
                                       buildingName: StudentCenterCatalog.buildingName)
            }
        }
        .fullScreenCover(item: active ? $cover : .constant(nil), onDismiss: scanDidClose) { cover in
            switch cover {
            case .scan: ScanView()
            case .demo: MapScreen(isDemo: true)
            }
        }
        .alert("Couldn’t open this floor", isPresented: Binding(get: { active && floorError != nil }, set: { if !$0 { floorError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(floorError ?? "") }
    }

    private var explorePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(assistant.isAvailable ? "Search or ask a question" : "Search this floor", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit {
                            searchFocused = false
                            if points.isEmpty, otherFloorResults.isEmpty, !live.isLoading { askTypedQuestion() }
                        }
                        .onChange(of: query) { _, value in if !value.isEmpty { detent = .height(440) } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Clear search")
                    } else if assistant.isAvailable {
                        Button(action: listen) {
                            Image(systemName: assistant.phase == .listening ? "waveform" : "mic.fill")
                                .foregroundStyle(Color.accentColor)
                                .symbolEffect(.variableColor.iterative, isActive: assistant.phase == .listening)
                        }
                        .accessibilityLabel(assistant.phase == .listening ? "Finish question" : "Ask a question by voice")
                    }
                }
                .padding(.horizontal, 12).frame(height: 48)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .intelligenceGlow(assistant.phase == .listening || assistant.phase == .thinking,
                                  in: RoundedRectangle(cornerRadius: 12))
                if isDemo {
                    Button { controller.stop(); dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Close demo")
                }
            }
            if assistant.phase != .idle {
                AssistantCard(assistant: assistant, onListen: listen, onShowPlace: showAssistantPlace)
            }
            if !isDemo { quickActions }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold()).lineLimit(2)
                Text(showsModel ? "Floor \(selectedLevel)" : "Floor \(selectedLevel) · \(coverageTitle)").font(.subheadline).foregroundStyle(.secondary)
            }
            livePositionStatus
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    if !routablePlaces.isEmpty {
                        Button { openDirections() } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill").font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Theme.brandGradient, in: Capsule())
                                .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                    if hasVisualFloor {
                        Button { detent = .height(440); query = "Elevator" } label: {
                            Label("Elevators", systemImage: "figure.roll").font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                    if hasMap, controller.canGuide, !isDemo {
                        Button(action: readSigns) {
                            Label("Read a sign", systemImage: "text.viewfinder").font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .accessibilityHint("Opens the camera to label doors from room and exit signs")
                    }
                    if hasMap, controller.map?.signPlaces.contains(where: { $0.signCategory == .exit }) == true {
                        Button(action: showNearestExit) {
                            Label("Nearest exit", systemImage: SignReading.Category.exit.symbolName).font(.subheadline.weight(.medium))
                        }
                        .accessibilityHint("Shows the closest exit read from a sign, with directions")
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.green)
                    }
                    if hasMap, controller.map?.signPlaces.contains(where: { $0.signCategory == .room }) == true {
                        Button { detent = .height(440); query = "Room" } label: {
                            Label("Rooms", systemImage: SignReading.Category.room.symbolName).font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.indigo)
                    }
                    if modelAvailable && hasMap {
                        Button { mapStyle = showsModel ? .scan : .model } label: {
                            Label(showsModel ? "Floor scan" : "3D model", systemImage: showsModel ? "map" : "cube")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
            }
            .scrollIndicators(.hidden).scrollClipDisabled()
            if !isDemo, localFloor == nil {
                Button { modal = .buildingDirections } label: {
                    Label("Between floors", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
            if showsModel, illustrationState == .failed {
                Text(hasMap ? "The 3D model couldn’t be opened. Showing the floor scan." : "The 3D map couldn’t be opened. Choose another floor.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if hasVisualFloor {
                if live.isLoading, points.isEmpty {
                    ProgressView("Finding nearby places…").frame(maxWidth: .infinity)
                } else if points.isEmpty, otherFloorResults.isEmpty, assistant.isAvailable,
                          !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: askTypedQuestion) {
                        Label("Ask InView “\(query)”", systemImage: "waveform")
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                } else if points.isEmpty, otherFloorResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    VStack(spacing: 0) {
                        ForEach(points) { point in
                            Button { selectPlace(MapPlace(point)) } label: { placeRow(point) }
                                .buttonStyle(.plain)
                            if point.id != points.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                }
                if !otherFloorResults.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Other floors").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(otherFloorResults) { result in
                            HStack(spacing: 14) {
                                Image(systemName: result.levelDelta > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .font(.title2).foregroundStyle(.secondary).frame(width: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title).font(.body.weight(.medium))
                                    Text(result.summary(direction: liveDirection(result))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let message = live.message, hasMap, liveScanID != nil {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if !showsModel {
                    Text(displayedPublishedVersion != nil && localFloor == nil
                         ? "Published map · Only the mapped area is shown."
                         : "Partial coverage · Scan locations haven’t been reviewed yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("There’s no published map for this floor. Choose another floor to explore.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Show Floor 2") { switchFloor(2) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var placementPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Model placement").font(.title2.bold())
                Spacer()
                Button("Done") { panel = .explore; detent = .height(240) }.fontWeight(.semibold)
            }
            Text("Match the model to familiar landmarks. Directions follow the floor scan.")
                .font(.subheadline).foregroundStyle(.secondary)
            placementSlider("Position across", value: $modelAcross, range: -15...15, suffix: "m")
            placementSlider("Position along", value: $modelAlong, range: -15...15, suffix: "m")
            placementSlider("Rotation", value: $modelRotation, range: -90...90, suffix: "°")
            placementSlider("Size", value: $modelScale, range: 0.5...1.5, suffix: "×")
            Button("Reset to elevator alignment") {
                modelAcross = 0; modelAlong = 0; modelRotation = 0; modelScale = 1
            }
        }
    }

    private func placementSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(suffix == "×" ? 2 : 1)))
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(suffix).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }

    /// Every account and map tool as its own button: a row on iPhone, a grid in the iPad panel.
    @ViewBuilder private var quickActions: some View {
        if usesSidePanel {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4, alignment: .top), count: 4), spacing: 14) {
                quickActionItems
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 4) { quickActionItems }
            }
            .scrollIndicators(.hidden).scrollClipDisabled()
        }
    }

    @ViewBuilder private var quickActionItems: some View {
        quickAction(account.isSignedIn ? "Account" : "Sign in",
                    symbol: account.isSignedIn ? "person.crop.circle.fill" : "person.fill",
                    color: .blue, label: account.isSignedIn ? "Your account" : "Sign in") { modal = .account }
        quickAction("Contribute", symbol: "viewfinder", color: .green, label: "Contribute a scan") { modal = .contribute }
        quickAction("Submissions", symbol: "tray.full.fill", color: .orange, label: "My submissions") { modal = .submissions }
        quickAction("Building", symbol: "building.2.fill", color: .indigo, label: "Building details") { modal = .building }
        quickAction("Saved maps", symbol: "map.fill", color: .teal, label: "Saved maps") { modal = .savedMaps }
        quickAction("Settings", symbol: "gearshape.fill", color: .gray, label: "Scan settings") { modal = .settings }
        #if DEBUG
        quickAction("Demo", symbol: "play.fill", color: .pink, label: "Navigation demo") { cover = .demo }
        #endif
    }

    private func quickAction(_ title: String, symbol: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { quickActionLabel(title, symbol: symbol, color: color) }
            .buttonStyle(QuickActionButtonStyle())
            .accessibilityLabel(label)
    }

    private func quickActionLabel(_ title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(color.gradient, in: Circle())
                .shadow(color: color.opacity(0.35), radius: 6, y: 3)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(minWidth: 70).frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Finding the person, or the reminder that their position is showing and the camera is on.
    @ViewBuilder private var livePositionStatus: some View {
        if !isDemo, controller.phase == .locating, controller.selectedDestination == nil {
            LocatingPanel(startView: controller.startView, isSlow: controller.isRelocalizationSlow, hint: controller.locatingHint, onRetry: controller.retryLocalization)
            Button("Stop finding my location") { controller.endGuidance() }.buttonStyle(.bordered)
            Toggle("Find me automatically when a map opens", isOn: $findsMeAutomatically).font(.subheadline)
        } else if controller.isLocated {
            HStack {
                Label(controller.isPositionReliable ? "Showing where you are" : "Reconnecting to your position",
                      systemImage: controller.isPositionReliable ? "location.fill" : "location.slash")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
                Spacer(minLength: 8)
                Button("Turn off") { controller.endGuidance() }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .accessibilityLabel("Turn off live location")
            }
        }
    }

    private func placeRow(_ point: AccessPoint) -> some View {
        HStack(spacing: 14) {
            KindBadge(point: point, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(point.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let result = live.result(for: point), livePins.contains(where: { $0.id == point.id }) {
                    Text(result.summary(direction: liveDirection(result))).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Floor \(selectedLevel) · \(point.kind.title)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var destinationPanel: some View {
        if assistant.phase != .idle {
            AssistantCard(assistant: assistant, onListen: listen, onShowPlace: showAssistantPlace)
        }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(panel == .chooseStart ? "Choose your starting point"
                     : panel == .directions ? "Directions"
                     : selectedModelPlace?.title ?? controller.selectedDestination?.title ?? "Directions")
                    .font(.title2.bold())
                Text("\(title) · Floor \(selectedLevel)").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                closeDestination()
                if modelAvailable { mapStyle = .model }
            } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel(selectedModelPlace == nil ? "Close directions" : "Close place")
        }
        if selectedModelPlace != nil {
            Text("Location from the walkthrough. Directions aren’t available for this area yet.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            if panel == .directions || panel == .chooseStart { routeFields }
            RoutePreferencePicker(selection: routePreferenceSelection)
            if panel == .chooseStart {
                Text("Tap your starting point on the Floor \(selectedLevel) map. You can drag and zoom to find it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Cancel") { panel = .directions }.buttonStyle(.bordered)
            } else if controller.phase == .locating, routeStart == .myLocation, panel == .directions {
                LocatingPanel(startView: controller.startView, isSlow: controller.isRelocalizationSlow, hint: controller.locatingHint, onRetry: controller.retryLocalization)
                Button("Cancel") { controller.endGuidance(); showsAR = false }.buttonStyle(.bordered)
            } else if controller.phase == .navigating, previewStart == nil, let route = controller.route {
                RouteCard(route: route, onEnd: closeDestination)
                if let caption = controller.caption { Text(caption).font(.subheadline).foregroundStyle(.secondary) }
                RouteStepsList(route: route, isLive: true)
            } else if controller.phase == .arrived, previewStart == nil {
                ArrivedPanel(destination: controller.route?.destination, onDone: closeDestination)
            } else if isFindingRoute || (controller.phase == .routing && previewStart == nil) {
                ProgressView("Finding a route…").frame(maxWidth: .infinity, minHeight: 70)
            } else if panel == .directions {
                routeResult
            } else {
                placeSummary
            }
        }
    }

    /// From and To, like Maps: the start can be "My location", a place on this floor or a point on the map.
    private var routeFields: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                Menu {
                    if canUseMyLocation {
                        Button("My location", systemImage: "location.fill") { setRouteStart(.myLocation) }
                    }
                    Section("Places on Floor \(selectedLevel)") {
                        ForEach(routablePlaces.filter { $0.id != controller.selectedDestination?.id }) { place in
                            Button(place.title, systemImage: place.kind.symbolName) { setRouteStart(.place(place.id)) }
                        }
                    }
                    Button("Choose on map", systemImage: "hand.tap") { beginChoosingStart() }
                } label: {
                    routeField("From", value: routeStartTitle, symbol: "circle.circle.fill", tint: Theme.route)
                }
                Divider().padding(.leading, 44)
                Menu {
                    ForEach(routablePlaces.filter { routeStart != .place($0.id) }) { place in
                        Button(place.title, systemImage: place.kind.symbolName) { setRouteDestination(place) }
                    }
                } label: {
                    routeField("To", value: controller.selectedDestination?.title, symbol: "mappin.circle.fill", tint: .red)
                }
            }
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { swapTurns += 1; swapRoute() } label: {
                Image(systemName: "arrow.up.arrow.down").font(.body.weight(.semibold)).frame(width: 40, height: 40)
                    .rotationEffect(.degrees(Double(swapTurns) * 180))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: swapTurns)
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle)
            .disabled(!canSwapRoute)
            .accessibilityLabel("Swap start and destination")
        }
        .sensoryFeedback(.selection, trigger: controller.selectedDestination?.id)
        .sensoryFeedback(.selection, trigger: swapTurns)
    }

    private func routeField(_ label: String, value: String?, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value ?? (label == "From" ? "Choose a starting point" : "Choose a destination"))
                    .font(.body.weight(.medium)).foregroundStyle(value == nil ? .secondary : .primary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value ?? "not chosen")")
    }

    private var routeStartTitle: String? {
        switch routeStart {
        case .myLocation: "My location"
        case .place(let id): routablePlaces.first { $0.id == id }?.title
        case .mapPoint: "Point on the map"
        case nil: nil
        }
    }

    /// The route between the chosen points, its length and time, and every turn.
    @ViewBuilder private var routeResult: some View {
        let route = previewStart != nil ? previewRoute : controller.phase == .ready ? controller.route : nil
        if controller.selectedDestination == nil {
            Text("Choose where you’re going, or tap a place on the map.").font(.subheadline).foregroundStyle(.secondary)
        } else if controller.phase == .loading, routeStart == nil {
            ProgressView("Preparing saved location data…")
        } else if routeStart == nil {
            Text("Choose a starting point: a place on this floor, or a point on the map.").font(.subheadline).foregroundStyle(.secondary)
        } else if let message = routeMessage ?? (controller.phase == .noRoute ? controller.caption : nil) {
            Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
        } else if let route {
            RouteSummaryCard(route: route)
            if let warning = route.unmappedWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.color(for: .warning))
            }
            if routeStart == .myLocation { startButton }
            if let routeCheck {
                VStack(alignment: .leading, spacing: 4) {
                    Label(routeCheck.headline, systemImage: routeCheck.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(routeCheck.isWarning ? Theme.color(for: .warning) : Color.primary)
                    ForEach(routeCheck.details, id: \.self) { detail in
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !isDemo, displayedPublishedVersion == nil {
                Text("This scan hasn’t been verified for accessibility. Check that the way is clear.").font(.footnote).foregroundStyle(.secondary)
            }
            RouteStepsList(route: route)
        } else if routeStart == .myLocation {
            Text("InView finds where you are with the camera, then shows the way on the map.")
                .font(.subheadline).foregroundStyle(.secondary)
            startButton
        }
    }

    private var startButton: some View {
        Button(action: startLiveDirections) {
            Label(isDemo ? "Start preview" : "Start", systemImage: "location.north.line.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(controller.phase == .loading)
    }

    /// A place's details before directions are asked for.
    @ViewBuilder private var placeSummary: some View {
        if let message = routeMessage ?? (controller.phase == .noRoute ? controller.caption : nil) {
            Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
        }
        Text(controller.selectedDestination?.requiresAssistance == true ? "May need staff assistance"
             : selectedDestinationIsModelPlace ? "Location on the 3D model. Directions cover only part of this floor."
             : "Location from the floor scan")
            .font(.subheadline).foregroundStyle(.secondary)
        if controller.isLocated, let route = controller.route {
            Label("\(Int(route.length.rounded())) m from you", systemImage: "location.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
        }
        Button(action: openDirections) {
            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
        if !canUseMyLocation {
            Text(controller.phase == .loading ? "Preparing saved location data…"
                 : "Live location isn’t available for this map yet. Choose a starting point instead.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var arUnavailableSheet: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Live location isn’t ready here", systemImage: "location.slash")
            } description: {
                Text(controller.phase == .loading ? "Preparing saved location data. Try again in a moment."
                     : hasMap ? controller.unavailableReason ?? "Live location hasn’t been added for this map. You can still preview a route."
                     : hasVisualFloor ? "Live location hasn’t been added for this floor. You can still explore the 3D map."
                     : "A floor map and a scan of the space are needed before InView can find you.")
            } actions: {
                Button("Return to map") { modal = nil }.buttonStyle(.borderedProminent)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { modal = nil } } }
        }
    }

    private var coverageTitle: String {
        guard hasMap else { return "No map yet" }
        if isDemo { return "Example map" }
        if localFloor != nil { return "Saved scan" }
        return displayedPublishedVersion != nil ? "Published map" : "Scanned area"
    }

    private func mapAvailable(on level: Int) -> Bool {
        if localFloor != nil { return MapStore.savedBuildings().first { $0.id == localFloor?.identity.buildingID }?.floors.contains { $0.identity.level == level } == true }
        return library.release(for: level) != nil || StudentCenterCatalog.coverage(for: level) == .scannedArea
            || StudentCenterCatalog.hasEstimatedModel(on: level)
    }

    private func acceptedRelease(for level: Int) -> BuildingMapLibrary.Release? {
        guard let release = library.release(for: level),
              level != 2 || StudentCenterLocalization.mapFromWorld(for: release.map) != nil else { return nil }
        return release
    }

    private func switchFloor(_ level: Int) {
        guard !isDemo else { return }
        closeDestination()
        selectedLevel = level
        detailScene = nil; showsScanDetail = false
        illustrationState = .loading
        if StudentCenterCatalog.hasEstimatedModel(on: level), localFloor == nil { mapStyle = .model }
        if let localFloor {
            if let floor = MapStore.savedBuildings().first(where: { $0.id == localFloor.identity.buildingID })?.floors.first(where: { $0.identity.level == level }) {
                selectSavedFloor(floor)
            }
        } else if let release = acceptedRelease(for: level) {
            openRelease(release)
        } else if level == 2 {
            sourceLevel = 2
            displayedPublishedVersion = nil
            let map = StudentCenterCatalog.map()
            controller.reload(map: map, usesBundledMap: true)
            sceneGeneration += 1
            scene = StudentCenterCatalog.scene()
            isPreparedScene = scene != nil
        } else {
            // An illustration can be browsed without borrowing another floor's measured map.
            sourceLevel = level
            displayedPublishedVersion = nil
            controller.showSharedMap(nil)
            sceneGeneration += 1
            scene = nil; isPreparedScene = false
        }
        resetID += 1
    }

    private func selectPlace(_ place: MapPlace) {
        guard panel != .chooseStart else { return }
        // Live pins sit on this floor's measured map, so the on-device planner can route to them.
        let measured = hasMap ? controller.map?.points.first(where: { $0.id == place.id })
            ?? livePins.first(where: { $0.id == place.id }) : nil
        let modeled = modelPoints.first(where: { $0.id == place.id })
        guard measured != nil || modeled != nil else { return }
        let destination = measured ?? (modelHasMatchingMap ? modeled : nil)
        if panel == .directions, let destination {
            setRouteDestination(destination)
            return
        }
        closeDestination()
        selectedModelPlace = destination == nil ? modeled : nil
        if let destination { controller.selectDestination(destination) }
        query = ""; searchFocused = false
        panel = .place; detent = .height(440)
    }

    /// Every floor's places as the map shows them when that floor is opened.
    private var assistantContext: GeminiAssistantClient.Context {
        guard !isDemo, localFloor == nil else {
            let user = controller.isPositionReliable ? controller.position.map { (floor: sourceLevel, position: $0) } : nil
            return .init(buildingName: title, currentFloor: selectedLevel, floors: [
                .init(level: sourceLevel, summary: coverageTitle.lowercased(), points: controller.map?.points ?? [], landmarks: [])],
                user: user)
        }
        let floors = StudentCenterCatalog.floorLevels.map { level in
            // The same map switchFloor opens for this level.
            let release = acceptedRelease(for: level)
            let map = release?.map ?? (level == StudentCenterCatalog.floorLevel ? StudentCenterCatalog.map() : nil)
            let hasModel = StudentCenterCatalog.hasEstimatedModel(on: level)
            let parts = [hasModel ? "3D model" : nil,
                         map == nil ? nil : release != nil ? "published floor map" : "partial floor scan"]
                .compactMap { $0 }
            return GeminiAssistantClient.Context.Floor(level: level,
                summary: parts.isEmpty ? "no map yet" : parts.joined(separator: " and "),
                points: map?.points ?? [], landmarks: hasModel ? StudentCenterCatalog.modelLandmarks(for: level) : [])
        }
        return .init(buildingName: "\(title), \(StudentCenterCatalog.universityName)", currentFloor: selectedLevel, floors: floors)
    }

    private func listen() {
        searchFocused = false
        detent = .height(440)
        assistant.listen(context: assistantContext)
    }

    private func askTypedQuestion() {
        guard assistant.isAvailable, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searchFocused = false
        detent = .height(440)
        assistant.ask(query, context: assistantContext)
        query = ""
    }

    private func showAssistantPlace() {
        guard let place = assistant.place else { return }
        let style = mapStyle
        if place.floor != selectedLevel { switchFloor(place.floor) }
        if !displayPoints.contains(where: { $0.id == place.id }), modelAvailable { mapStyle = .model }
        // A style change closes any open place as it settles, so the place opens after it.
        if mapStyle == style { revealPlace(place.id) } else { pendingAssistantPlace = place.id }
    }

    private func revealPlace(_ id: UUID) {
        guard let point = displayPoints.first(where: { $0.id == id }) else { return }
        selectPlace(MapPlace(point))
        // A shared map can preview directions from a chosen start without live positioning.
        if assistant.wantsDirections, assistant.place?.id == id,
           let destination = controller.selectedDestination, destination.id == id {
            if controller.canGuide {
                routeStart = .myLocation
                controller.navigate(to: destination, nearestOfKind: assistant.wantsNearest)
                panel = .directions; detent = .height(440)
            } else {
                openDirections()
            }
        }
    }

    /// Opens From and To. The start defaults to the person's location where InView can find them.
    private func openDirections() {
        searchFocused = false
        selectedModelPlace = nil
        if routeStart == nil, canUseMyLocation { routeStart = .myLocation }
        panel = .directions; detent = .height(440)
        updateRoute()
    }

    private func setRouteStart(_ start: RouteStart) {
        if start != .myLocation, [.routing, .navigating, .arrived, .noRoute].contains(controller.phase) {
            controller.endNavigation()
        }
        routeStart = start
        panel = .directions
        updateRoute()
    }

    private func setRouteDestination(_ place: AccessPoint) {
        if routeStart == .place(place.id) { routeStart = nil }
        if [.routing, .navigating, .arrived, .noRoute].contains(controller.phase) { controller.endNavigation() }
        controller.selectDestination(place)
        updateRoute()
    }

    private var canSwapRoute: Bool {
        if case .place = routeStart { return controller.selectedDestination != nil }
        return false
    }

    private func swapRoute() {
        guard case .place(let id) = routeStart, let start = routablePlaces.first(where: { $0.id == id }),
              let destination = controller.selectedDestination else { return }
        routeStart = .place(destination.id)
        setRouteDestination(start)
    }

    /// Previews the route from a chosen place or point. From "My location", the live session routes once it finds the person.
    private func updateRoute() {
        routeGeneration += 1
        previewRoute = nil; previewStart = nil; routeMessage = nil; routeCheck = nil; isFindingRoute = false
        guard controller.selectedDestination != nil else { return }
        switch routeStart {
        case .place(let id):
            if let start = routablePlaces.first(where: { $0.id == id }) { chooseStart(start.floorPoint) }
        case .mapPoint(let point):
            chooseStart(point)
        case .myLocation, nil:
            break
        }
    }

    private func startLiveDirections() {
        guard let destination = controller.selectedDestination else { return }
        if isDemo { controller.navigateToNearest() } else { controller.navigate(to: destination, nearestOfKind: false) }
    }

    private func locateMe() {
        searchFocused = false
        // A saved map is still loading its live-location data; finding starts once it's ready.
        if controller.phase == .loading, hasMap, !isDemo { controller.findRider(); return }
        guard hasMap, controller.canGuide, !isDemo else { modal = .arUnavailable; return }
        switch controller.phase {
        case .browsing: controller.findRider()
        case .locating: if controller.selectedDestination == nil { controller.endGuidance() }
        default: resetID += 1
        }
    }

    private func beginChoosingStart() {
        guard hasMap, selectedModelPlace == nil else { return }
        // The planner uses the floor's routing coverage in either visual layer.
        if controller.isLocated { controller.endNavigation() }
        else if controller.phase != .loading { controller.endGuidance() }
        showsAR = false
        previewRoute = nil; previewStart = nil; routeMessage = nil; routeCheck = nil
        isFindingRoute = false
        routeGeneration += 1
        panel = .chooseStart; detent = .height(440)
    }

    private func chooseStart(_ start: SIMD2<Float>) {
        guard hasMap, let map = controller.map, let destination = controller.selectedDestination else { return }
        previewStart = start; panel = .directions; isFindingRoute = true
        routeGeneration += 1
        let generation = routeGeneration
        let preference = routePreference
        previewRoute = nil
        routeMessage = nil
        routeCheck = nil
        let scanID = liveScanID
        let placeID = live.result(for: destination).flatMap { $0.kind == "place" ? $0.sourceID : nil }
        let isModelDestination = selectedDestinationIsModelPlace
        Task {
            let route = await Task.detached(priority: .userInitiated) {
                RoutePlanner(map: map).route(from: start, to: destination, conditions: preference.navigationConditions(map: map))
            }.value
            guard generation == routeGeneration else { return }
            isFindingRoute = false
            previewRoute = route
            // The device route is shown right away; the building map's check follows when it answers.
            if let scanID, route != nil {
                Task {
                    let check = await ServerRouteCheck.run(scanID: scanID, map: map, start: start, destination: destination,
                                                           placeID: placeID, preference: preference)
                    guard generation == routeGeneration else { return }
                    routeCheck = check
                }
            }
            if route == nil {
                let message = preference == .stepFree
                    ? "No step-free route was found within the mapped area. Your route preference hasn’t been relaxed."
                    : "No route was found within this floor’s mapped area."
                routeMessage = message + (isModelDestination ? " Directions cover only part of the 3D model." : "")
            }
        }
    }

    private func routePreferenceChanged() {
        controller.setRoutePreference(routePreference)
        routeGeneration += 1
        previewRoute = nil
        routeMessage = nil
        isFindingRoute = false
        if let previewStart { chooseStart(previewStart) }
    }

    private func enterAR() {
        searchFocused = false
        if showsAR { showsAR = false; return }
        guard hasMap, controller.canGuide, !isDemo else { modal = .arUnavailable; return }
        previewRoute = nil; previewStart = nil
        showsAR = true
        controller.beginGuidance(thenRoute: controller.selectedDestination != nil)
    }

    /// Opens the AR camera in sign-reading mode; reading starts once the person is found on the map.
    private func readSigns() {
        searchFocused = false
        guard hasMap, controller.canGuide, !isDemo else { modal = .arUnavailable; return }
        if !showsAR { enterAR() }
        readsSigns = true
    }

    /// The closest exit read from a sign: from where the person is, else the chosen start, else the scan origin.
    private func showNearestExit() {
        let from = (controller.isPositionReliable ? controller.position : nil) ?? previewStart ?? .zero
        guard let exit = controller.map?.signPlaces.filter({ $0.signCategory == .exit })
            .min(by: { simd_distance($0.floorPoint, from) < simd_distance($1.floorPoint, from) }) else { return }
        selectPlace(MapPlace(exit))
    }

    private func signPreview(_ sighting: SignReader.Sighting) -> AccessPoint? {
        guard let map = controller.map else { return nil }
        let existing = map.signPlaces.first { $0.sign?.reading.title == sighting.reading.title
            && simd_distance($0.sign?.signPosition ?? .zero, sighting.position) < 1 }
        return SignPlaceBinder.place(for: sighting.reading, text: sighting.text, sign: sighting.position,
                                     viewer: sighting.viewer, in: map, id: existing?.id ?? sighting.id,
                                     confidence: sighting.check == .confirmed ? 0.95 : 0.85)
            .withReader(sighting.check)
    }

    private func tagSign(_ point: AccessPoint) async -> String? {
        guard controller.canTagSigns else { return nil }
        guard let result = try? await controller.tagSign(point) else { return nil }
        UIAccessibility.post(notification: .announcement, argument: "\(result.point.title) added to the map")
        if !result.isNew { return "Updated the place already on this door" }
        return result.point.sign?.door != nil ? "Door tagged · searchable and routable now" : "Pinned on the map"
    }

    private func showTaggedPlace(_ point: AccessPoint) {
        readsSigns = false
        showsAR = false
        if let stored = controller.map?.points.first(where: { $0.id == point.id }) { selectPlace(MapPlace(stored)) }
    }

    private func closeDestination() {
        controller.clearDirections()
        routeStart = nil
        showsAR = false; panel = .explore
        routeGeneration += 1
        previewRoute = nil; previewStart = nil; routeMessage = nil; routeCheck = nil; isFindingRoute = false
        selectedModelPlace = nil
        detent = .height(240)
    }

    private func selectSavedFloor(_ floor: SavedFloor) {
        do { try MapStore.selectFloor(buildingID: floor.identity.buildingID, floorID: floor.id) }
        catch { floorError = error.localizedDescription }
    }

    private func openSavedFloor(_ floor: SavedFloor) {
        closeDestination()
        localFloor = floor; selectedLevel = floor.identity.level; sourceLevel = floor.identity.level
        displayedPublishedVersion = nil
        let map = MapStore.load()
        controller.reload(map: map)
        sceneGeneration += 1
        let generation = sceneGeneration
        scene = nil; isPreparedScene = false
        detailScene = nil; showsScanDetail = false
        let captureID = MapStore.activeCaptureID
        resetID += 1
        Task {
            let saved = try? await ScanWork.run { CaptureStore.loadSavedScene() }
            guard generation == sceneGeneration, localFloor?.id == floor.id else { return }
            if let saved { scene = saved }
            else {
                let prepared = await Task.detached(priority: .userInitiated) { map.flatMap(VenueScene.make) }.value
                guard generation == sceneGeneration else { return }
                scene = prepared
            }
            if let captureID {
                let detail = try? await ScanWork.run { CaptureStore.loadDetailScene(for: captureID) }
                guard generation == sceneGeneration else { return }
                detailScene = detail
            }
        }
    }

    private func openRelease(_ release: BuildingMapLibrary.Release) {
        guard localFloor == nil else { return }
        closeDestination()
        sourceLevel = release.floor; selectedLevel = release.floor
        displayedPublishedVersion = release.version
        detailScene = nil; showsScanDetail = false
        controller.showSharedMap(release.map)
        sceneGeneration += 1
        let generation = sceneGeneration
        scene = nil; isPreparedScene = false
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { VenueScene.make(from: release.map) }.value
            guard generation == sceneGeneration else { return }
            scene = prepared
        }
        resetID += 1
    }

    private func scanDidClose() {
        guard let floor = MapStore.currentFloor else { return }
        openSavedFloor(floor)
    }

    private func mapInset(_ geometry: GeometryProxy) -> CGFloat {
        if usesSidePanel { return geometry.safeAreaInsets.bottom + 16 }
        let height: CGFloat = detent == .height(240) ? 240 : detent == .height(440) ? 440 : geometry.size.height * 0.85
        return height + geometry.safeAreaInsets.bottom
    }
}

/// The app's own building: only what's been measured, from published maps and the bundled scan.
private struct BuildingDetailsSheet: View {
    @ObservedObject var library: BuildingMapLibrary
    let releaseForFloor: (Int) -> BuildingMapLibrary.Release?
    let onShowFloor: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(StudentCenterCatalog.buildingName).font(.title2.bold())
                        Text(StudentCenterCatalog.universityName).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    ForEach(StudentCenterCatalog.floorLevels, id: \.self) { level in
                        if let map = measuredMap(on: level) {
                            Button { onShowFloor(level); dismiss() } label: {
                                floorRow(level, status: status(on: level), contents: map.contentSummary)
                            }
                        } else {
                            floorRow(level, status: "Not scanned yet", contents: nil)
                        }
                    }
                } footer: {
                    Text("Floors list what scans measured. Scan a floor with Contribute to add it.")
                }
                if let message = library.message {
                    Section { Text(message).foregroundStyle(.secondary); Button("Check for updates") { Task { await library.refresh() } } }
                }
            }
            .navigationTitle("Building details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// A published map, or the scan the app ships with for its floor.
    private func measuredMap(on level: Int) -> VenueMap? {
        releaseForFloor(level)?.map ?? (level == StudentCenterCatalog.floorLevel ? StudentCenterCatalog.map() : nil)
    }

    private func status(on level: Int) -> String {
        guard let release = releaseForFloor(level) else { return "Scanned area" }
        let date = Date(timeIntervalSince1970: release.publishedAt)
        return "Published map · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func floorRow(_ level: Int, status: String, contents: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up").font(.title3)
                .foregroundStyle(contents == nil ? Color.secondary : Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Floor \(level)").font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(status).font(.caption).foregroundStyle(.secondary)
                if let contents { Text(contents).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// What a live nearby search depends on; the search itself skips moves under a few meters.
private struct LiveSearchTrigger: Equatable {
    var scanID: String?
    var origin: SIMD3<Float>
    var query: String
    var pointCount: Int
}

/// Quick actions shrink a little under the finger, like Home Screen icons.
private struct QuickActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Rings spreading from the middle of the camera preview while ARKit searches for the scanned room.
private struct RadarPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { ring in
                    let phase = (time / 2 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(Color.white.opacity(0.8 * (1 - phase)), lineWidth: 2)
                        .frame(width: 20 + 140 * phase, height: 20 + 140 * phase)
                }
                Image(systemName: "location.viewfinder").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .shadow(radius: 3)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The moment the camera recognizes the room: a green seal and "Found you".
private struct FoundYouBadge: View {
    @State private var bounce = 0

    var body: some View {
        Label {
            Text("Found you").font(.headline)
        } icon: {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.white, Theme.routeStart)
                .font(.title2)
                .symbolEffect(.bounce, value: bounce)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
        .onAppear { bounce += 1 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Found your location")
    }
}
