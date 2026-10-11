import AccessCore
import SwiftUI
import simd

/// One map, with search, place details and directions sharing the same sheet.
struct MapScreen: View {
    private enum Panel { case explore, place, directions, chooseStart, placement }
    private enum MapStyle: String { case model, scan }
    private enum Modal: String, Identifiable {
        case account, contribute, submissions, building, settings, arUnavailable, buildingDirections
        var id: String { rawValue }
    }
    private enum Cover: String, Identifiable {
        case scan, demo
        var id: String { rawValue }
    }

    let isDemo: Bool
    @StateObject private var controller: NavigationController
    @StateObject private var library = BuildingMapLibrary()
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
    @State private var detent = PresentationDetent.height(240)
    @State private var showsMainSheet = false
    @State private var previewRoute: Route?
    @State private var previewStart: SIMD2<Float>?
    @State private var isFindingRoute = false
    @State private var routeMessage: String?
    @State private var routeGeneration = 0
    @State private var floorError: String?
    @State private var selectedModelPlace: AccessPoint?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

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
    private var activeRoute: Route? { controller.route ?? previewRoute }
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
    private var registrationMap: VenueMap? {
        let candidate = selectedLevel == 2 && hasMap ? controller.map : library.release(for: 2)?.map
        if let candidate, StudentCenterModelAlignment.transform(for: candidate) != nil { return candidate }
        return StudentCenterCatalog.map()
    }
    private var modelTransform: simd_float4x4? {
        guard modelAvailable, let map = registrationMap,
              let base = StudentCenterModelAlignment.transform(for: map, floor: selectedLevel),
              let landmark = map.points.first(where: { $0.id == StudentCenterModelAlignment.firstElevatorID }) else { return nil }
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

    /// These places are for browsing only and are never inserted into the measured route map.
    private var modelPoints: [AccessPoint] {
        guard showsModel, let transform = modelTransform else { return [] }
        return StudentCenterCatalog.modelLandmarks(for: selectedLevel).compactMap { landmark in
            if hasMap, landmark.title == "Lifts", controller.map?.points.contains(where: { $0.kind == .elevator }) == true { return nil }
            let ground = SIMD4(landmark.position.x, StudentCenterCatalog.modelFloorY(for: selectedLevel) ?? 0, landmark.position.z, 1)
            let position = transform * ground
            return AccessPoint(id: landmark.id, kind: landmark.title == "Lifts" ? .elevator : .destination,
                name: landmark.title, position: SIMD3(position.x, position.y, position.z), source: .manual, confidence: 0.5)
        }
    }

    private var displayPoints: [AccessPoint] { (hasMap ? controller.map?.points ?? [] : []) + modelPoints }

    private func bounded(_ value: Double, in range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound
    }
    private var points: [AccessPoint] {
        guard hasVisualFloor else { return [] }
        let all = displayPoints
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(text) || $0.kind.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    mapSurface(bottomInset: mapInset(geometry))
                        .ignoresSafeArea()
                    floatingControls
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsMainSheet) { mainSheet }
        .background(Color(.systemGroupedBackground))
        .preferredColorScheme(.light)
        .onAppear { controller.setRoutePreference(routePreference); showsMainSheet = true }
        .task {
            controller.start()
            if !isDemo {
                if let release = library.release(for: 2) { openRelease(release) }
                await library.refresh()
                if selectedLevel == 2, panel == .explore, query.isEmpty,
                   let release = library.release(for: 2), release.version != displayedPublishedVersion {
                    openRelease(release)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MapStore.selectionDidChange)) { _ in
            if cover == nil, let floor = MapStore.currentFloor { openSavedFloor(floor) }
        }
        .onDisappear { controller.stop() }
        .onChange(of: mapStyle) { _, _ in
            if selectedModelPlace != nil { closeDestination() }
            resetID += 1
        }
        .onChange(of: routePreference) { _, _ in routePreferenceChanged() }
        .onChange(of: controller.phase) { _, phase in
            if phase == .locating { showsAR = true; panel = .directions }
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

    @ViewBuilder private func mapSurface(bottomInset: CGFloat) -> some View {
        if showsAR, controller.canGuide {
            ViewContainer(view: controller.arView)
                .overlay(alignment: .top) {
                    if !controller.isPositionReliable, controller.phase != .locating {
                        Text("Position lost · Look around to reconnect")
                            .font(.subheadline.weight(.medium))
                            .padding(12).background(.regularMaterial, in: Capsule())
                            .padding(.top, 85)
                    } else if let route = controller.route, controller.phase == .navigating {
                        NextStepBanner(route: route, caption: controller.caption).padding(.horizontal, 16).padding(.top, 85)
                    }
                }
        } else if hasVisualFloor {
            NavigationMapSurface(scene: hasMap ? scene : StudentCenterCatalog.estimatedScene(for: selectedLevel),
                map: hasMap ? controller.map : nil, presentation: .indoor,
                topDown: topDown, resetID: resetID, bottomInset: bottomInset,
                groundFloorY: hasMap ? controller.map?.floorY : modelFloorY,
                route: hasMap ? activeRoute : nil,
                userPosition: hasMap ? (controller.isPositionReliable ? controller.position : previewStart) : nil,
                userHeading: hasMap && controller.isPositionReliable ? controller.heading : nil,
                destination: hasMap ? controller.selectedDestination?.floorPoint : nil,
                destinationTitle: hasMap ? controller.selectedDestination?.title : nil,
                places: displayPoints.map(MapPlace.init),
                onSelectPlace: selectPlace,
                onSelectFloorPoint: hasMap && panel == .chooseStart ? chooseStart : nil,
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
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .padding(.bottom, bottomInset)
                    } else if showsModel, illustrationState == .failed, !hasMap {
                        ContentUnavailableView("3D map unavailable", systemImage: "cube",
                            description: Text("Choose another floor to explore."))
                            .padding(.bottom, bottomInset)
                    }
                }
        } else {
            Color(red: 0.92, green: 0.93, blue: 0.91)
                .overlay {
                    ContentUnavailableView("No map for Floor \(selectedLevel)", systemImage: "map",
                        description: Text("This floor hasn’t been mapped yet."))
                        .padding(.bottom, bottomInset)
                }
        }
    }

    private var floatingControls: some View {
        HStack(alignment: .top) {
            Button(action: enterAR) {
                Label(showsAR ? "Map" : "View in AR", systemImage: showsAR ? "map.fill" : "viewfinder")
                    .font(.subheadline.weight(.semibold)).padding(.horizontal, 15).frame(height: 46)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel(showsAR ? "Return to map" : "Enter AR mode")
            Spacer()
            VStack(spacing: 12) {
                if !isDemo {
                    VStack(spacing: 2) {
                        ForEach([3, 2, 1], id: \.self) { level in
                            Button { switchFloor(level) } label: {
                                Text("\(level)").font(.system(.body, design: .rounded).weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(selectedLevel == level ? Color.white : .primary)
                                    .background(selectedLevel == level ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Floor \(level)\(mapAvailable(on: level) ? "" : ", no map")")
                            .accessibilityAddTraits(selectedLevel == level ? .isSelected : [])
                        }
                    }
                    .padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
                    .frame(width: 52)
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
                            if showsModel {
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
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
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
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private var mainSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if panel == .explore { explorePanel }
                else if panel == .placement { placementPanel }
                else { destinationPanel }
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.height(240), .height(440), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(.regularMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(440)))
        .interactiveDismissDisabled()
        .sheet(item: $modal) { modal in
            switch modal {
            case .account: AccountExperienceView()
            case .contribute: ContributeExperienceView()
            case .submissions: MySubmissionsView()
            case .settings: BackendSettingsView()
            case .building: BuildingDetailsSheet(library: library)
            case .arUnavailable: arUnavailableSheet
            case .buildingDirections:
                BuildingDirectionsView(venueID: "student-center-east", graphID: "student-center-east",
                                       buildingName: StudentCenterCatalog.buildingName)
            }
        }
        .fullScreenCover(item: $cover, onDismiss: scanDidClose) { cover in
            switch cover {
            case .scan: ScanView()
            case .demo: MapScreen(isDemo: true)
            }
        }
        .alert("Couldn’t open this floor", isPresented: Binding(get: { floorError != nil }, set: { if !$0 { floorError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(floorError ?? "") }
    }

    private var explorePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this floor", text: $query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .onChange(of: query) { _, value in if !value.isEmpty { detent = .height(440) } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12).frame(height: 48)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                appMenu
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold()).lineLimit(2)
                Text(showsModel ? "Floor \(selectedLevel)" : "Floor \(selectedLevel) · \(coverageTitle)").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if hasVisualFloor {
                    Button { detent = .height(440); query = "Elevator" } label: {
                        Label("Elevators", systemImage: "figure.roll").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
                if modelAvailable && hasMap {
                    Button { mapStyle = showsModel ? .scan : .model } label: {
                        Label(showsModel ? "Floor scan" : "3D model", systemImage: showsModel ? "map" : "cube")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
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
                if points.isEmpty {
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
                if !showsModel {
                    Text(library.isReviewed(floor: selectedLevel) && localFloor == nil
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

    private var appMenu: some View {
        Menu {
            if isDemo {
                Button("Close demo", systemImage: "xmark") { controller.stop(); dismiss() }
            } else {
                Button(account.isSignedIn ? "Your account" : "Sign in", systemImage: "person.crop.circle") { modal = .account }
                Button("Contribute a scan", systemImage: "viewfinder") { modal = .contribute }
                Button("My submissions", systemImage: "tray") { modal = .submissions }
                Divider()
                Button("Building details", systemImage: "building.2") { modal = .building }
                if localFloor != nil { Button("Student Center East", systemImage: "map") { localFloor = nil; switchFloor(2) } }
                let buildings = MapStore.savedBuildings()
                if !buildings.isEmpty {
                    Menu("Saved maps", systemImage: "map") {
                        ForEach(buildings) { building in
                            Section(building.name) {
                                ForEach(building.floors) { floor in
                                    Button(floor.name) { selectSavedFloor(floor) }
                                }
                            }
                        }
                    }
                }
                Button("Scan settings", systemImage: "gearshape") { modal = .settings }
                #if DEBUG
                Divider()
                Button("Navigation demo", systemImage: "play") { cover = .demo }
                #endif
            }
        } label: {
            Image(systemName: account.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 32, weight: .light)).foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 48)
        }
        .accessibilityLabel("Account and menu")
    }

    private func placeRow(_ point: AccessPoint) -> some View {
        HStack(spacing: 14) {
            KindBadge(kind: point.kind, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(point.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text("Floor \(selectedLevel) · \(point.kind.title)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var destinationPanel: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(panel == .chooseStart ? "Choose your starting point" : selectedModelPlace?.title ?? controller.selectedDestination?.title ?? "Directions")
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
        if selectedModelPlace == nil {
            RoutePreferencePicker(selection: routePreferenceSelection)
        }
        if panel == .chooseStart {
            Text("Tap your location on the Floor \(selectedLevel) map. You can drag and zoom to find it.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Cancel") { panel = .place }.buttonStyle(.bordered)
        } else if selectedModelPlace != nil {
            Text("Location from the walkthrough. Directions aren’t available for this area yet.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if controller.phase == .locating {
            LocatingPanel(startView: controller.startView, isSlow: controller.isRelocalizationSlow, onRetry: controller.retryLocalization)
            Button("Cancel") { controller.endGuidance(); showsAR = false; panel = .place }.buttonStyle(.bordered)
        } else if controller.phase == .navigating, let route = controller.route {
            RouteCard(route: route, onEnd: closeDestination)
            if let caption = controller.caption { Text(caption).font(.subheadline).foregroundStyle(.secondary) }
        } else if controller.phase == .arrived {
            ArrivedPanel(destination: controller.route?.destination, onDone: closeDestination)
        } else if isFindingRoute || controller.phase == .routing {
            ProgressView("Finding a route…").frame(maxWidth: .infinity, minHeight: 70)
        } else if let previewRoute {
            Label("\(Int(previewRoute.length.rounded())) m · \(previewRoute.preference.title)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.headline).foregroundStyle(Color.accentColor)
            Text("From your chosen starting point. Follow signs and check that the way is clear.")
                .font(.subheadline).foregroundStyle(.secondary)
            if !library.isReviewed(floor: selectedLevel) { Text("This scan hasn’t been verified for accessibility.").font(.footnote).foregroundStyle(.secondary) }
            HStack {
                Button("Change start") { beginChoosingStart() }.buttonStyle(.bordered)
                Button("View in AR", action: enterAR).buttonStyle(.borderedProminent)
            }
        } else {
            if let message = routeMessage ?? (controller.phase == .noRoute ? controller.caption : nil) {
                Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
            }
            if panel == .place {
                Text(controller.selectedDestination?.requiresAssistance == true ? "May need staff assistance" : "Location from the floor scan")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button {
                if isDemo || controller.canGuide { controller.navigateToNearest(); panel = .directions }
                else { beginChoosingStart() }
            } label: {
                Label(isDemo ? "Start preview" : controller.canGuide ? "Directions" : "Preview a route", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            if !controller.canGuide {
                Text("Live positioning is not available for this map yet.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var arUnavailableSheet: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("AR isn’t ready for this floor", systemImage: "viewfinder")
            } description: {
                Text(hasMap ? "The map is available, but live positioning hasn’t been added yet. Explore in 3D or preview a route on the map." : hasVisualFloor ? "Live positioning hasn’t been added for this floor. You can still explore the 3D map." : "A floor map and live positioning are needed before AR guidance is available.")
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
        return library.isReviewed(floor: selectedLevel) ? "Published map" : "Scanned area"
    }

    private func mapAvailable(on level: Int) -> Bool {
        if localFloor != nil { return MapStore.savedBuildings().first { $0.id == localFloor?.identity.buildingID }?.floors.contains { $0.identity.level == level } == true }
        return library.release(for: level) != nil || StudentCenterCatalog.coverage(for: level) == .scannedArea
            || StudentCenterCatalog.hasEstimatedModel(on: level)
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
        } else if let release = library.release(for: level) {
            openRelease(release)
        } else if level == 2 {
            sourceLevel = 2
            displayedPublishedVersion = nil
            let map = StudentCenterCatalog.map()
            controller.showSharedMap(map)
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
        let measured = hasMap ? controller.map?.points.first(where: { $0.id == place.id }) : nil
        let modeled = modelPoints.first(where: { $0.id == place.id })
        guard measured != nil || modeled != nil else { return }
        closeDestination()
        selectedModelPlace = measured == nil ? modeled : nil
        if let measured { controller.selectDestination(measured) }
        query = ""; searchFocused = false
        panel = .place; detent = .height(440)
    }

    private func beginChoosingStart() {
        guard hasMap, selectedModelPlace == nil else { return }
        // Start selection and route previews use the measured geometry, including its gaps.
        mapStyle = .scan
        controller.endGuidance()
        showsAR = false
        previewRoute = nil; previewStart = nil; routeMessage = nil
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
        Task {
            let route = await Task.detached(priority: .userInitiated) {
                RoutePlanner(map: map).route(from: start, to: destination, conditions: preference.conditions())
            }.value
            guard generation == routeGeneration else { return }
            isFindingRoute = false
            previewRoute = route
            routeMessage = route == nil
                ? preference == .stepFree
                    ? "No step-free route was found within the mapped area. Your route preference hasn’t been relaxed."
                    : "No route was found within this floor’s mapped area."
                : nil
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

    private func closeDestination() {
        controller.endGuidance()
        showsAR = false; panel = .explore
        routeGeneration += 1
        previewRoute = nil; previewStart = nil; routeMessage = nil; isFindingRoute = false
        selectedModelPlace = nil
        controller.selectDestination(nil)
        detent = .height(240)
    }

    private func selectSavedFloor(_ floor: SavedFloor) {
        do { try MapStore.selectFloor(buildingID: floor.identity.buildingID, floorID: floor.id) }
        catch { floorError = error.localizedDescription }
    }

    private func openSavedFloor(_ floor: SavedFloor) {
        closeDestination()
        localFloor = floor; selectedLevel = floor.identity.level; sourceLevel = floor.identity.level
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
        let height: CGFloat = detent == .height(240) ? 240 : detent == .height(440) ? 440 : geometry.size.height * 0.85
        return height + geometry.safeAreaInsets.bottom
    }
}

private struct BuildingDetailsSheet: View {
    @ObservedObject var library: BuildingMapLibrary
    @State private var showsIllustration = false
    @State private var illustrationFloor = 2
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
                        HStack {
                            Text("Floor \(level)")
                            Spacer()
                            Text(library.isReviewed(floor: level) ? "Published map" : StudentCenterCatalog.hasEstimatedModel(on: level) ? "3D map" : "No map")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Route previews cover the mapped portion of Floor 2.")
                }
                Section {
                    ForEach([2, 3], id: \.self) { level in
                    Button { illustrationFloor = level; showsIllustration = true } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            if let url = StudentCenterCatalog.illustrationPreviewURL(for: level), let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().scaledToFill().frame(height: 180).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Floor \(level)").font(.headline).foregroundStyle(.primary)
                                    Text("Explore in 3D").font(.subheadline).foregroundStyle(Color.accentColor)
                                }
                                Spacer()
                                Image(systemName: "cube").font(.title2)
                            }
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain)
                    }
                } footer: {
                    Text("Floor 2 follows the supplied scans. Floor 3 is estimated from the walkthrough.")
                }
                if let message = library.message {
                    Section { Text(message).foregroundStyle(.secondary); Button("Check for updates") { Task { await library.refresh() } } }
                }
            }
            .navigationTitle("Building details").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(isPresented: $showsIllustration) {
                NavigationStack {
                    BuildingIllustrationView(floor: illustrationFloor).ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Floor \(illustrationFloor)").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsIllustration = false } } }
                }.preferredColorScheme(.light)
            }
        }
    }
}
