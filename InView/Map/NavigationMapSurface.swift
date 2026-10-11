import AccessCore
import simd
import SwiftUI

/// Indoor and geographic renderers present the same navigation session.
struct NavigationMapSurface: View {
    let scene: ProcessedScene?
    let map: VenueMap?
    var selectedFloorID: String? = nil
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
    var onSelectFloorPoint: ((SIMD2<Float>) -> Void)? = nil
    var initialYaw: Float? = nil
    var isPreparedScene = false
    var illustrationURL: URL? = nil
    var mapFromIllustration: simd_float4x4? = nil
    var showsIllustration = false
    var showsScanOutline = true
    var onIllustrationState: ((IllustrationLayerState) -> Void)? = nil
    var splatURL: URL? = nil
    var pausesSplat = false
    var onSplatState: ((SplatLayer.State?) -> Void)? = nil
    var detailedScan = false
    var detailScene: ProcessedScene? = nil
    let onPlaceBuilding: () -> Void

    var body: some View {
        Group {
            if let scene = displayedScene {
                if isPreparedScene && !detailedScan {
                    surface(scene: scene, map: map, isRouteFloor: true)
                } else {
                    FinalMapSurface(scene: scene, map: map, selectedFloorID: selectedFloorID,
                                    detailedScan: detailedScan) { finalScene, displayMap, isRouteFloor in
                        surface(scene: finalScene, map: displayMap, isRouteFloor: isRouteFloor)
                    }
                }
            } else {
                surface(scene: nil, map: map, isRouteFloor: true)
            }
        }
    }

    /// Optional detail must belong to the same saved scan and floor. The measured map remains
    /// authoritative for routes, destinations and floor selection in either presentation.
    private var displayedScene: ProcessedScene? {
        guard detailedScan, let scene, let detailScene,
              detailScene.sourceScanID == scene.sourceScanID, detailScene.mapID == scene.mapID,
              detailScene.floorID == scene.floorID, detailScene.coordinates == scene.coordinates else { return scene }
        return detailScene
    }

    @ViewBuilder private func surface(scene: ProcessedScene?, map: VenueMap?, isRouteFloor: Bool) -> some View {
        if presentation == .indoor {
            indoor(scene: scene, map: map, isRouteFloor: isRouteFloor)
        } else if let map, let reference = map.geographicReference, (try? reference.validate()) != nil {
            GeographicMapboxView(scene: scene, map: map, reference: reference,
                                accessToken: AppConfig.mapboxAccessToken,
                                routePoints: isRouteFloor ? route?.waypoints ?? [] : [],
                                userPosition: isRouteFloor ? userPosition : nil,
                                destination: isRouteFloor ? destination : nil,
                                destinationTitle: isRouteFloor ? destinationTitle : nil,
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

    @ViewBuilder private func indoor(scene: ProcessedScene?, map: VenueMap?, isRouteFloor: Bool) -> some View {
        if let scene {
            RoomMapCanvas(scene: scene, selectedObjectID: .constant(nil), showsLabels: false,
                          floorFootprints: map?.footprints.filter { $0.kind == .floor } ?? [],
                          topDown: topDown, resetID: resetID, showsDetails: detailedScan,
                          viewportBottomInset: bottomInset, viewportTopInset: 110,
                          routePoints: isRouteFloor ? route?.waypoints ?? [] : [],
                          userPosition: isRouteFloor ? userPosition : nil,
                          userHeading: isRouteFloor ? userHeading : nil, floorY: map?.floorY ?? groundFloorY ?? 0,
                          destination: isRouteFloor ? destination : nil,
                          destinationTitle: isRouteFloor ? destinationTitle : nil, isNavigating: true,
                          places: isRouteFloor ? (places.isEmpty ? MapPlace.places(in: map) : places) : [],
                          onSelectPlace: isRouteFloor ? onSelectPlace : nil,
                          onSelectFloorPoint: isRouteFloor ? onSelectFloorPoint : nil,
                          initialYaw: initialYaw,
                          illustrationURL: illustrationURL, mapFromIllustration: mapFromIllustration,
                          showsIllustration: showsIllustration, showsScanOutline: showsScanOutline,
                          onIllustrationState: onIllustrationState,
                          splatURL: isRouteFloor ? splatURL : nil,
                          splatCeiling: splatCeiling(map: map), pausesSplat: pausesSplat,
                          onSplatState: onSplatState)
        } else if let map {
            MapPreviewView(map: map, route: route, userPosition: userPosition,
                           userHeading: userHeading ?? 0, showsScanStart: false)
                .padding(.bottom, bottomInset)
                .background(Color(.systemGroupedBackground))
        }
    }

    /// Use the displayed floor's elevation when clipping a photoreal layer.
    private func splatCeiling(map: VenueMap?) -> Float {
        let floors = (map?.footprints ?? []).filter { $0.kind == .floor }.compactMap(\.bottom)
        return (floors.max() ?? map?.floorY ?? 0) + 1.3
    }
}

/// Rebuild presentation geometry away from the UI thread, once per map/floor revision.
/// A replacement floor never displays the preceding floor while preparation is in flight.
struct FinalMapSurface<Content: View>: View {
    let scene: ProcessedScene
    var map: VenueMap? = nil
    var selectedFloorID: String? = nil
    var detailedScan = false
    @ViewBuilder let content: (ProcessedScene, VenueMap?, Bool) -> Content

    private struct Request: Equatable {
        var scene: ProcessedScene
        var map: VenueMap?
        var selectedFloorID: String?
        var detailedScan: Bool
        var retry: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.scene == rhs.scene, lhs.selectedFloorID == rhs.selectedFloorID,
                  lhs.detailedScan == rhs.detailedScan, lhs.retry == rhs.retry else { return false }
            switch (lhs.map, rhs.map) {
            case (nil, nil): return true
            case let (a?, b?):
                return a.createdAt == b.createdAt && a.floorY == b.floorY && a.footprints == b.footprints
                    && a.points == b.points && a.geographicReference == b.geographicReference
                    && a.requiresMeasuredFloorCoverage == b.requiresMeasuredFloorCoverage
                    && a.requiresOptimizedLocalization == b.requiresOptimizedLocalization
            default: return false
            }
        }
    }
    private struct Prepared {
        var request: Request
        var scene: ProcessedScene
        var map: VenueMap?
        var isRouteFloor: Bool
    }
    private struct Failure {
        var request: Request
        var message: String
    }
    @State private var prepared: Prepared?
    @State private var failure: Failure?
    @State private var retry = 0
    private var request: Request {
        Request(scene: scene, map: map, selectedFloorID: selectedFloorID, detailedScan: detailedScan, retry: retry)
    }

    var body: some View {
        let request = request
        Group {
            if let prepared, prepared.request == request {
                content(prepared.scene, prepared.map, prepared.isRouteFloor)
            } else if let failure, failure.request == request {
                ContentUnavailableView {
                    Label("Map unavailable", systemImage: "map")
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("Try again") { self.failure = nil; retry += 1 }
                }
            } else {
                ProgressView("Preparing map…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .task(id: request) {
            failure = nil
            do {
                let result = try await ScanWork.run {
                    try FinalMapSceneBuilder.validateInput(request.scene,
                        floorFootprints: request.map?.footprints.filter { $0.kind == .floor } ?? [],
                        floorY: request.map?.floorY)
                    var inputScene = try Self.measuredOutlineScene(request.scene)
                    if !request.detailedScan {
                        inputScene.meshes.removeAll { $0.sourceID == ReconstructedMesh.sourceID }
                    }
                    let floor = IndoorFloorContent(scene: inputScene, map: request.map, selectedFloorID: request.selectedFloorID)
                    var final = try FinalMapSceneBuilder.make(from: floor.scene ?? inputScene,
                        floorFootprints: floor.map?.footprints.filter { $0.kind == .floor } ?? [],
                        floorY: floor.floor?.elevation ?? floor.map?.floorY)
                    if request.detailedScan {
                        final.meshes = (floor.scene ?? inputScene).meshes.filter {
                            $0.sourceID == ReconstructedMesh.sourceID && $0.classifications != nil
                        }
                        try final.validate()
                    }
                    return (final, floor.map, floor.isRouteFloor)
                }
                try Task.checkCancellation()
                prepared = Prepared(request: request, scene: result.0, map: result.1, isRouteFloor: result.2)
            } catch is CancellationError {
                // Changing floors or closing the map cancels reconstruction and publication.
            } catch {
                guard !Task.isCancelled else { return }
                failure = Failure(request: request, message: "This scan could not be prepared. Please try again.")
            }
        }
    }

    /// Both saved map outlines and native RoomPlan polygons describe the same measured floor.
    private nonisolated static func measuredOutlineScene(_ scene: ProcessedScene) throws -> ProcessedScene {
        var result = scene
        for index in result.surfaces.indices {
            let surface = result.surfaces[index]
            guard surface.kind == "floor", surface.polygonCorners == nil, let outline = surface.outline else { continue }
            guard (3...128).contains(outline.count), outline.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else {
                throw SceneValidationError.invalid("The map contains an invalid floor outline.")
            }
            let pose = surface.mapFromSurface
            let matrix = simd_float4x4(columns: (
                SIMD4(pose[0], pose[1], pose[2], pose[3]), SIMD4(pose[4], pose[5], pose[6], pose[7]),
                SIMD4(pose[8], pose[9], pose[10], pose[11]), SIMD4(pose[12], pose[13], pose[14], pose[15])
            ))
            let inverse = simd_inverse(matrix)
            result.surfaces[index].polygonCorners = outline.map { corner in
                let local = inverse * SIMD4(corner[0], pose[13], corner[1], 1)
                return [local.x, local.y, local.z]
            }
        }
        return result
    }
}

/// Floor menus need metadata only; clipping a dense scene belongs in background preparation.
struct MapFloorChoice {
    let floor: IndoorSceneFloor?
    let isRouteFloor: Bool

    init(scene: ProcessedScene?, map: VenueMap?, selectedFloorID: String?) {
        let floors = scene.map(IndoorSceneFloors.floors(in:)) ?? []
        let routeElevation = map?.floorY ?? floors.first?.elevation ?? 0
        let routeFloor = floors.min { abs($0.elevation - routeElevation) < abs($1.elevation - routeElevation) }
        floor = floors.first { $0.id == selectedFloorID } ?? routeFloor
        isRouteFloor = floor == nil || floor?.id == routeFloor?.id
    }
}
