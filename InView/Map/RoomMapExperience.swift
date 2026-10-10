import AccessCore
import SwiftUI

/// The processed scan is reviewed as a navigation map before it is saved.
struct RoomMapExperience: View {
    let scene: ProcessedScene
    var map: VenueMap? = nil
    var title = "Review map"
    let onClose: () -> Void
    var primaryTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var reviewDestination: AnyView? = nil
    var currentMapPosition: (() -> SIMD2<Float>?)? = nil
    var onPlaceBuilding: ((BuildingMapReference) throws -> Void)? = nil
    var error: Binding<String?> = .constant(nil)

    @State private var topDown = false
    @State private var resetID = 0
    @State private var showsReview = false
    @State private var showsSheet = false
    @State private var presentation = MapPresentation.indoor
    @State private var showsPlacement = false
    @State private var selectedFloorID: String?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                NavigationMapSurface(scene: floorContent.scene, map: floorContent.map, presentation: presentation,
                                     topDown: topDown, resetID: resetID,
                                     bottomInset: 210 + geometry.safeAreaInsets.bottom,
                                     groundFloorY: map?.floorY,
                                     destination: floorContent.isRouteFloor ? map?.points.first?.floorPoint : nil,
                                     destinationTitle: floorContent.isRouteFloor ? map?.points.first?.title : nil) { showsPlacement = true }
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) {
                FloorPicker(floors: floors, floorID: floorSelection).padding(.horizontal, 16).padding(.top, 8)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close, action: onClose)
                }
                MapToolbarItems(presentation: $presentation, topDown: $topDown,
                                canPlaceBuilding: map != nil && onPlaceBuilding != nil,
                                onRecenter: { resetID += 1 }, onPlaceBuilding: { showsPlacement = true })
            }
            .sheet(isPresented: $showsSheet) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title).font(.panelTitle)
                    HStack(spacing: 10) {
                        if let secondaryTitle {
                            Button(action: { showsReview = true }) {
                                Label(secondaryTitle, systemImage: "list.bullet").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                        if let primaryTitle, let primaryAction {
                            Button(action: primaryAction) {
                                Label(primaryTitle, systemImage: "checkmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                    .controlSize(.large)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .presentationDetents([.height(210)])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .interactiveDismissDisabled()
                .fullScreenCover(isPresented: $showsReview) { reviewDestination }
                .fullScreenCover(isPresented: $showsPlacement) {
                    if let map, let onPlaceBuilding {
                        BuildingPlacementView(map: map, currentMapPosition: currentMapPosition) { reference in
                            try onPlaceBuilding(reference)
                            presentation = .mapbox
                            resetID += 1
                        }
                    }
                }
                .alert("Couldn’t save the map", isPresented: Binding(
                    get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }
                )) { Button("OK", role: .cancel) {} } message: { Text(error.wrappedValue ?? "") }
            }
            .task {
                if !showsSheet, map?.geographicReference != nil { presentation = .mapbox }
                showsSheet = true
            }
        }
        .preferredColorScheme(.light)
    }

    private var floors: [IndoorSceneFloor] { IndoorSceneFloors.floors(in: scene) }
    private var floorSelection: Binding<String?> {
        Binding(get: { floorContent.floor?.id }, set: { selectedFloorID = $0; resetID += 1 })
    }
    private var floorContent: IndoorFloorContent { IndoorFloorContent(scene: scene, map: map, selectedFloorID: selectedFloorID) }
}

enum RoomItemStyle {
    static func title(_ category: String) -> String {
        switch category.lowercased() {
        case "sofa": return "Sofa"
        case "chair": return "Chair"
        case "table": return "Table"
        case "storage", "cabinet": return "Storage"
        case "plant": return "Plant"
        case "rug": return "Rug"
        case "bed": return "Bed"
        case "sink": return "Sink"
        case "refrigerator": return "Refrigerator"
        case "stove": return "Stove"
        case "oven": return "Oven"
        case "dishwasher": return "Dishwasher"
        case "washer_dryer": return "Washer & dryer"
        case "toilet": return "Toilet"
        case "bathtub": return "Bathtub"
        case "television": return "TV"
        case "fireplace": return "Fireplace"
        case "stairs": return "Stairs"
        default: return "Object"
        }
    }
    static func symbol(_ category: String) -> String {
        switch category.lowercased() {
        case "sofa": return "sofa.fill"
        case "chair": return "chair.lounge.fill"
        case "table": return "table.furniture.fill"
        case "storage", "cabinet": return "cabinet.fill"
        case "plant": return "leaf.fill"
        case "rug": return "square.fill"
        case "bed": return "bed.double.fill"
        case "sink": return "sink.fill"
        case "television": return "tv.fill"
        case "refrigerator": return "refrigerator.fill"
        case "stove", "oven": return "oven.fill"
        case "washer_dryer": return "washer.fill"
        case "dishwasher": return "dishwasher.fill"
        case "toilet": return "toilet.fill"
        case "bathtub": return "bathtub.fill"
        case "fireplace": return "fireplace.fill"
        case "stairs": return "stairs"
        default: return "cube.fill"
        }
    }
    static func tint(_ category: String) -> Color {
        Theme.furniture
    }
}
