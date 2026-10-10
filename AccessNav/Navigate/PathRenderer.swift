import AccessCore
import RealityKit
import UIKit

/// Draws the route as chevrons on the floor and a floating label over every access point.
/// Everything hangs off one anchor at the venue origin, so it is laid out in venue coordinates.
@MainActor
final class PathRenderer {
    private static let chevronSpacing: Float = 0.5
    /// No chevrons right under the user's feet, where they'd only be seen from above.
    private static let chevronStart: Float = 0.6
    private static let maxChevrons = 60

    private let anchor: AnchorEntity
    private let routeRoot = Entity()
    private let chevron: ModelEntity
    private var markers: [UUID: PointMarker] = [:]
    private var floorY: Float

    init(scene: RealityKit.Scene, venue: VenueFrame, map: VenueMap) {
        anchor = AnchorEntity(world: venue.worldFromVenue)
        floorY = map.floorY
        chevron = ModelEntity(mesh: Self.chevronMesh(), materials: [UnlitMaterial(color: .systemBlue)])
        anchor.addChild(routeRoot)
        for point in map.points {
            let marker = PointMarker(point: point, floorY: floorY)
            markers[point.id] = marker
            anchor.addChild(marker.entity)
        }
        scene.addAnchor(anchor)
    }

    func show(_ route: Route) {
        routeRoot.children.removeAll()
        for (position, direction) in Self.samples(along: route.waypoints).prefix(Self.maxChevrons) {
            let entity = chevron.clone(recursive: false)
            entity.position = SIMD3(position.x, floorY + 0.03, position.y)
            // The chevron points along local +x; turn it to face the route direction (x, z).
            entity.orientation = simd_quatf(angle: atan2(-direction.y, direction.x), axis: [0, 1, 0])
            routeRoot.addChild(entity)
        }
        for (id, marker) in markers {
            marker.show(id == route.destination.id ? .destination(distance: route.length) : .idle)
        }
    }

    func showArrival(at point: AccessPoint) {
        routeRoot.children.removeAll()
        markers[point.id]?.show(.arrived)
    }

    func clearRoute() {
        routeRoot.children.removeAll()
        markers.values.forEach { $0.show(.idle) }
    }

    /// Re-seats everything on the real floor once ARKit finds it, correcting RoomPlan's estimate.
    func setFloorHeight(_ y: Float) {
        guard abs(y - floorY) > 0.03 else { return }
        let shift = y - floorY
        floorY = y
        for marker in markers.values { marker.entity.position.y += shift }
        for child in routeRoot.children { child.position.y += shift }
    }

    /// Evenly spaced points along a polyline, each with the direction of travel.
    private static func samples(along points: [SIMD2<Float>]) -> [(SIMD2<Float>, SIMD2<Float>)] {
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        var next = chevronStart
        var travelled: Float = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = simd_distance(a, b)
            guard length > 1e-4 else { continue }
            let direction = (b - a) / length
            while next <= travelled + length {
                result.append((a + direction * (next - travelled), direction))
                next += chevronSpacing
            }
            travelled += length
        }
        return result
    }

    /// A flat arrowhead lying on the floor, pointing along +x.
    private static func chevronMesh() -> MeshResource {
        var descriptor = MeshDescriptor(name: "chevron")
        descriptor.positions = MeshBuffers.Positions([[0.16, 0, 0], [-0.12, 0, 0.15], [-0.04, 0, 0], [-0.12, 0, -0.15]])
        let triangles: [UInt32] = [0, 1, 2, 0, 2, 3]
        // Both windings, so it shows from above whatever the face culling.
        descriptor.primitives = .triangles(triangles + triangles.reversed())
        return try! MeshResource.generate(from: [descriptor])
    }
}

/// A pole with a billboard label standing over one access point.
@MainActor
private final class PointMarker {
    enum State: Equatable {
        case idle
        case destination(distance: Float)
        case arrived
    }

    let entity = Entity()
    private let point: AccessPoint
    private let head: ModelEntity
    private let text = ModelEntity()
    private let plate = ModelEntity()
    private var currentLabel = ""

    init(point: AccessPoint, floorY: Float) {
        self.point = point
        entity.position = SIMD3(point.position.x, floorY, point.position.z)

        let pole = ModelEntity(mesh: .generateBox(width: 0.03, height: 1.3, depth: 0.03), materials: [UnlitMaterial(color: .white)])
        pole.position.y = 0.65
        head = ModelEntity(mesh: .generateSphere(radius: 0.07), materials: [UnlitMaterial(color: .systemBlue)])
        head.position.y = 1.35

        let label = Entity()
        label.position.y = 1.6
        label.components.set(BillboardComponent())
        label.addChild(plate)
        label.addChild(text)

        entity.addChild(pole)
        entity.addChild(head)
        entity.addChild(label)
        show(.idle)
    }

    func show(_ state: State) {
        switch state {
        case .idle:
            setLabel(point.kind.title, accent: .systemBlue, background: .black)
            entity.scale = .one
        case .destination(let distance):
            setLabel("\(point.kind.title) · \(Int(distance.rounded())) m", accent: .systemBlue, background: .systemBlue)
            entity.scale = SIMD3(repeating: 1.3)
        case .arrived:
            setLabel("Arrived · \(point.kind.title)", accent: .systemGreen, background: .systemGreen)
            entity.scale = SIMD3(repeating: 1.3)
        }
    }

    private func setLabel(_ string: String, accent: UIColor, background: UIColor) {
        head.model?.materials = [UnlitMaterial(color: accent)]
        guard string != currentLabel else {
            plate.model?.materials = [UnlitMaterial(color: background)]
            return
        }
        currentLabel = string
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.1, weight: .semibold),
            alignment: .center
        )
        text.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let bounds = mesh.bounds
        text.position = SIMD3(-bounds.center.x, -bounds.center.y, 0.005)
        let backing = MeshResource.generatePlane(width: bounds.extents.x + 0.1, height: bounds.extents.y + 0.06, cornerRadius: 0.03)
        plate.model = ModelComponent(mesh: backing, materials: [UnlitMaterial(color: background)])
    }
}
