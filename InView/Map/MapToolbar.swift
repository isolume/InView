import AccessCore
import SwiftUI

/// The map options and 2D / 3D toggle, shared by navigation and scan review so both maps have the same
/// controls in the same places.
struct MapToolbarItems: ToolbarContent {
    @Binding var presentation: MapPresentation
    @Binding var topDown: Bool
    /// False when the building can't be placed here, which also rules out the surroundings view.
    var canPlaceBuilding = true
    let onRecenter: () -> Void
    let onPlaceBuilding: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Map appearance", selection: $presentation) {
                    ForEach(MapPresentation.allCases) { option in
                        Text(option.title).tag(option).disabled(option != .indoor && !canPlaceBuilding)
                    }
                }
                Divider()
                Button("Recenter", systemImage: Theme.Symbol.recenter, action: onRecenter)
                Button("Place building", systemImage: Theme.Symbol.placeBuilding, action: onPlaceBuilding)
                    .disabled(!canPlaceBuilding)
            } label: {
                Label("Map options", systemImage: "ellipsis")
            }
            Button(topDown ? "Show 3D" : "Show 2D", systemImage: Theme.Symbol.dimension(switchingToTopDown: !topDown)) {
                topDown.toggle()
            }
            .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// Indoor floors as a vertical glass control on the map's edge, highest floor on top, like Apple Maps.
struct FloorPicker: View {
    let floors: [IndoorSceneFloor]
    @Binding var floorID: String?
    @Namespace private var selection

    var body: some View {
        if floors.count > 1 {
            VStack(spacing: 2) {
                ForEach(Array(floors.enumerated().reversed()), id: \.element.id) { index, floor in
                    let isSelected = floor.id == floorID
                    Button { floorID = floor.id } label: {
                        Text("\(index + 1)")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white : .primary)
                            .frame(width: 40, height: 40)
                            .background {
                                if isSelected {
                                    Circle().fill(Theme.accent).matchedGeometryEffect(id: "selected", in: selection)
                                }
                            }
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(floor.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
            .animation(.smooth, value: floorID)
            .sensoryFeedback(.selection, trigger: floorID)
        }
    }
}
