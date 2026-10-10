import AccessCore
import SwiftUI

struct ProcessedSceneView: View {
    let scene: ProcessedScene
    @State private var selectedObjectID: String?

    var body: some View {
        FinalMapSurface(scene: scene) { finalScene, _, _ in
            RoomMapCanvas(scene: finalScene, selectedObjectID: $selectedObjectID, showsLabels: false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
