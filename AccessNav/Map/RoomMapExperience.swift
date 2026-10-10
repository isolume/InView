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
    var error: Binding<String?> = .constant(nil)

    @State private var topDown = false
    @State private var resetID = 0
    @State private var showsReview = false
    @State private var showsSheet = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                RoomMapCanvas(scene: scene, selectedObjectID: .constant(nil), showsLabels: false,
                              topDown: topDown, resetID: resetID,
                              viewportBottomInset: 210 + geometry.safeAreaInsets.bottom,
                              floorY: map?.floorY ?? 0,
                              destination: map?.points.first?.floorPoint,
                              destinationTitle: map?.points.first?.title,
                              isNavigating: true)
                    .ignoresSafeArea()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Recenter", systemImage: "scope") { resetID += 1 }.labelStyle(.iconOnly)
                    Button(topDown ? "3D" : "2D") { topDown.toggle() }
                        .accessibilityLabel(topDown ? "Show 3D" : "Show 2D")
                }
            }
            .sheet(isPresented: $showsSheet) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title).font(.title2.bold())
                    HStack {
                        if let primaryTitle, let primaryAction {
                            Button(primaryTitle, action: primaryAction)
                                .frame(maxWidth: .infinity).buttonStyle(.borderedProminent)
                        }
                        if let secondaryTitle {
                            Button(secondaryTitle) { showsReview = true }.buttonStyle(.bordered)
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
                .alert("Couldn’t save the map", isPresented: Binding(
                    get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }
                )) { Button("OK", role: .cancel) {} } message: { Text(error.wrappedValue ?? "") }
            }
            .task { showsSheet = true }
        }
        .preferredColorScheme(.light)
    }
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
        Color(red: 0.50, green: 0.53, blue: 0.54)
    }
}
