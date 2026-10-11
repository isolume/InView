import SwiftUI
import AccessCore

@main
struct InViewApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--floor-picker-preview") {
                ScanFloorPickerPreview(isSwitch: false)
            } else if ProcessInfo.processInfo.arguments.contains("--floor-switch-preview") {
                ScanFloorPickerPreview(isSwitch: true)
            } else if ProcessInfo.processInfo.arguments.contains("--scan-review-preview") {
                ScanReviewPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--scan-review-failure-preview") {
                ScanReviewFailurePreview()
            } else if ProcessInfo.processInfo.arguments.contains("--building-directions-preview") {
                BuildingDirectionsPreview()
            } else if ProcessInfo.processInfo.arguments.contains("--final-map-preview")
                        || ProcessInfo.processInfo.arguments.contains("--scan-mesh-preview") {
                FinalMapPreview()
            } else {
                MapScreen()
            }
            #else
            MapScreen()
            #endif
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator fixtures exercise the production map view without touching saved scans or the camera.
private struct FinalMapPreview: View {
    @State private var scene: ProcessedScene?
    @State private var map: VenueMap?
    @State private var failure: String?
    @State private var topDown = false

    var body: some View {
        Group {
            if let scene {
                if ProcessInfo.processInfo.arguments.contains("--scan-mesh-preview") {
                    NavigationStack {
                        RoomMapCanvas(scene: scene, selectedObjectID: .constant(nil), topDown: topDown,
                                      showsDetails: true, viewportBottomInset: 210, viewportTopInset: 110)
                            .ignoresSafeArea()
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(topDown ? "3D" : "2D") { topDown.toggle() }
                                }
                            }
                            .safeAreaInset(edge: .bottom) {
                                Text("Original scan").font(.title2.bold())
                                    .frame(maxWidth: .infinity, minHeight: 180)
                                    .background(.regularMaterial)
                            }
                    }
                } else {
                    RoomMapExperience(scene: scene, map: map, title: "Map preview", onClose: {})
                }
            } else if let failure {
                ContentUnavailableView("Preview unavailable", systemImage: "map", description: Text(failure))
            } else {
                ProgressView("Loading preview…")
            }
        }
        .task {
            do {
                let arguments = ProcessInfo.processInfo.arguments
                if let sceneIndex = arguments.firstIndex(of: "--map-scene-file"), sceneIndex + 1 < arguments.count {
                    let sceneURL = URL(fileURLWithPath: arguments[sceneIndex + 1])
                    if let captureIndex = arguments.firstIndex(of: "--map-capture-file"), captureIndex + 1 < arguments.count {
                        let captureURL = URL(fileURLWithPath: arguments[captureIndex + 1])
                        let loaded = try await ScanWork.run {
                            let snapshot = try NavigationDemo.load(sceneURL: sceneURL, captureURL: captureURL)
                            return (snapshot.scene, snapshot.map)
                        }
                        scene = loaded.0
                        var indoorMap = loaded.1
                        indoorMap.geographicReference = nil
                        map = indoorMap
                    } else {
                        scene = try await ScanWork.run {
                            let loaded = try JSONDecoder().decode(ProcessedScene.self, from: Data(contentsOf: sceneURL))
                            try loaded.validate()
                            return loaded
                        }
                    }
                } else {
                    scene = NavigationDemo.scene
                    var indoorMap = NavigationDemo.map
                    indoorMap?.geographicReference = nil
                    map = indoorMap
                }
            } catch { failure = error.localizedDescription }
        }
        .preferredColorScheme(.light)
    }
}
#endif
