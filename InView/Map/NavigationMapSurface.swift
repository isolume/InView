import AccessCore
import SwiftUI

/// Indoor and geographic renderers present the same navigation session.
struct NavigationMapSurface: View {
    let scene: ProcessedScene?
    let map: VenueMap?
    let presentation: MapPresentation
    let topDown: Bool
    let resetID: Int
    let bottomInset: CGFloat
    var groundFloorY: Float? = nil
    var route: Route? = nil
    var userPosition: SIMD2<Float>? = nil
    var userHeading: Float? = nil
    var destination: SIMD2<Float>? = nil
    var destinationTitle: String? = nil
    var places: [MapPlace] = []
    var onSelectPlace: ((MapPlace) -> Void)? = nil
    var splatURL: URL? = nil
    var pausesSplat = false
    var onSplatState: ((SplatLayer.State?) -> Void)? = nil
    let onPlaceBuilding: () -> Void

    var body: some View {
        if presentation == .indoor {
            indoor
        } else if let map, let reference = map.geographicReference, (try? reference.validate()) != nil {
            GeographicMapboxView(scene: scene, map: map, reference: reference,
                                accessToken: AppConfig.mapboxAccessToken,
                                routePoints: route?.waypoints ?? [], userPosition: userPosition,
                                destination: destination, destinationTitle: destinationTitle,
                                topDown: topDown, resetID: resetID, bottomInset: bottomInset,
                                groundFloorY: groundFloorY)
        } else {
            ContentUnavailableView {
                Label("Place the building", systemImage: "mappin.and.ellipse")
            } description: {
                Text("Align the scan with its surroundings to see it on the map.")
            } actions: {
                Button("Place building", systemImage: Theme.Symbol.placeBuilding, action: onPlaceBuilding)
                    .buttonStyle(.glassProminent)
                    .disabled(map == nil)
            }
            .padding(.bottom, bottomInset)
            .background(Color(.systemGroupedBackground))
        }
    }

    /// Cut the splat a little above the highest room's floor, like the model's cutaway walls.
    private var splatCeiling: Float {
        let floors = (map?.footprints ?? []).filter { $0.kind == .floor }.compactMap(\.bottom)
        return (floors.max() ?? map?.floorY ?? 0) + 1.3
    }

    @ViewBuilder private var indoor: some View {
        if let scene {
            RoomMapCanvas(scene: scene, selectedObjectID: .constant(nil), showsLabels: false,
                          floorFootprints: map?.footprints.filter { $0.kind == .floor } ?? [],
                          topDown: topDown, resetID: resetID, viewportBottomInset: bottomInset,
                          routePoints: route?.waypoints ?? [], userPosition: userPosition,
                          userHeading: userHeading, floorY: map?.floorY ?? 0,
                          destination: destination, destinationTitle: destinationTitle, isNavigating: true,
                          places: places, onSelectPlace: onSelectPlace,
                          splatURL: splatURL, splatCeiling: splatCeiling, pausesSplat: pausesSplat,
                          onSplatState: onSplatState)
        } else if let map {
            MapPreviewView(map: map, route: route, userPosition: userPosition,
                           userHeading: userHeading ?? 0, showsScanStart: false)
                .padding(.bottom, bottomInset)
                .background(Color(.systemGroupedBackground))
        }
    }
}
