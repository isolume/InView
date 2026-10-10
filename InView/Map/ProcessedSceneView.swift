import AccessCore
import SwiftUI

struct ProcessedSceneView: View {
    let scene: ProcessedScene
    @State private var selectedObjectID: String?

    var body: some View {
        RoomMapCanvas(scene: scene, selectedObjectID: $selectedObjectID, showsLabels: false)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
