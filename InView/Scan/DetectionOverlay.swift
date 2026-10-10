import ARKit
import AccessCore
import SwiftUI

/// Draws a colored 3D outline around everything marked so far, over the live scanning camera, the way
/// RoomPlan outlines furniture in white: blue elevators, teal ramps, red stairs. Dashed while a find is
/// still being confirmed, solid once it counts.
struct DetectionOverlay: View {
    @ObservedObject var detector: AccessibilityDetector
    let session: ARSession

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            Canvas { context, size in
                guard let frame = session.currentFrame else { return }
                let camera = frame.camera
                for sighting in detector.sightings {
                    draw(sighting, camera: camera, in: &context, size: size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ sighting: AccessibilityDetector.Sighting, camera: ARCamera, in context: inout GraphicsContext, size: CGSize) {
        let box = Self.box(for: sighting)
        let viewFromWorld = camera.transform.inverse
        // Skip anything behind the camera, where projection would flip it.
        guard box.allSatisfy({ (viewFromWorld * SIMD4($0, 1)).z < -0.1 }) else { return }
        let corners = box.map { camera.projectPoint($0, orientation: .portrait, viewportSize: size) }

        let color = sighting.kind.tint
        let style = StrokeStyle(lineWidth: sighting.isConfirmed ? 3 : 2, lineCap: .round, lineJoin: .round, dash: sighting.isConfirmed ? [] : [6, 5])
        var base = Path()
        base.addLines([corners[0], corners[1], corners[2], corners[3]])
        base.closeSubpath()
        context.fill(base, with: .color(color.opacity(sighting.isConfirmed ? 0.25 : 0.12)))

        var edges = Path()
        for (a, b) in Self.edges {
            edges.move(to: corners[a])
            edges.addLine(to: corners[b])
        }
        context.stroke(edges, with: .color(color), style: style)

        // Label floating over the top of the box.
        let top = corners[4...7].reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / 4, y: $0.y + $1.y / 4) }
        let title = sighting.isConfirmed ? sighting.name : "\(sighting.name)?"
        let text = context.resolve(Text(title).font(.caption.weight(.bold)).foregroundStyle(.white))
        let textSize = text.measure(in: CGSize(width: 240, height: 40))
        let plate = CGRect(x: top.x - textSize.width / 2 - 8, y: top.y - textSize.height - 12, width: textSize.width + 16, height: textSize.height + 8)
        context.fill(Path(roundedRect: plate, cornerRadius: plate.height / 2), with: .color(color.opacity(sighting.isConfirmed ? 0.95 : 0.6)))
        context.draw(text, at: CGPoint(x: plate.midX, y: plate.midY))
    }

    /// Bottom face (0–3) then top face (4–7) of a box standing on the floor spot and extending along `facing`.
    private static func box(for sighting: AccessibilityDetector.Sighting) -> [SIMD3<Float>] {
        // (width across, depth along facing, height, how far the box starts past the floor spot)
        let shape: (width: Float, depth: Float, height: Float, offset: Float) = switch sighting.kind {
        case .elevator: (1.0, 0.25, 2.1, 0.25)
        case .ramp: (1.2, 1.6, 0.35, 0)
        case .stairs: (AccessibilityDetector.spottedStairsSize.x, AccessibilityDetector.spottedStairsSize.y, 0.8, 0)
        }
        let along = sighting.facing
        let across = SIMD2(-along.y, along.x)
        let start = SIMD2(sighting.position.x, sighting.position.z) + along * shape.offset
        let floorY = sighting.position.y
        let footprint = [
            start - across * shape.width / 2,
            start + across * shape.width / 2,
            start + across * shape.width / 2 + along * shape.depth,
            start - across * shape.width / 2 + along * shape.depth,
        ]
        return footprint.map { SIMD3($0.x, floorY, $0.y) } + footprint.map { SIMD3($0.x, floorY + shape.height, $0.y) }
    }

    private static let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
}
