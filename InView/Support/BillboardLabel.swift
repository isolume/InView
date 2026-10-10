import RealityKit
import UIKit

/// A text label on a rounded plate that always turns to face the camera.
@MainActor
final class BillboardLabel {
    let entity = Entity()
    private let text = ModelEntity()
    private let plate = ModelEntity()
    private let fontSize: CGFloat
    private var current = ""

    init(fontSize: CGFloat = 0.1) {
        self.fontSize = fontSize
        entity.components.set(BillboardComponent())
        entity.addChild(plate)
        entity.addChild(text)
    }

    func set(_ string: String, background: UIColor) {
        guard string != current else {
            plate.model?.materials = [UnlitMaterial(color: background)]
            return
        }
        current = string
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: fontSize, weight: .semibold),
            alignment: .center
        )
        text.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let bounds = mesh.bounds
        text.position = SIMD3(-bounds.center.x, -bounds.center.y, 0.005)
        let padding = Float(fontSize)
        let backing = MeshResource.generatePlane(
            width: bounds.extents.x + padding,
            height: bounds.extents.y + padding * 0.6,
            cornerRadius: padding * 0.3
        )
        plate.model = ModelComponent(mesh: backing, materials: [UnlitMaterial(color: background)])
    }
}
