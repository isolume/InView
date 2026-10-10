import ARKit
import AccessCore
import SwiftUI

/// Pins a small colored tag over every find, on the live scanning camera: blue elevators, teal ramps, red
/// stairs. Tags are dashed and end in "?" while a find is still being confirmed.
///
/// Refreshes at 10 Hz: the tags only need to track the camera well enough to show where each find is.
struct DetectionOverlay: View {
    @ObservedObject var detector: AccessibilityDetector
    let session: ARSession

    /// Tags sit this far above the floor spot, so they don't cover the find itself.
    private static let tagHeight: Float = 0.3
    private static let refreshInterval: TimeInterval = 0.1
    /// Finds whose projection is this far outside the screen aren't laid out.
    private static let margin: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(placements(in: geometry.size)) { placement in
                        FindTag(sighting: placement.sighting)
                            // The tag's dot, at the bottom of its fixed frame, lands on the find.
                            .frame(height: FindTag.frameHeight, alignment: .bottom)
                            .position(x: placement.point.x, y: placement.point.y - FindTag.frameHeight / 2)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Placement: Identifiable {
        let sighting: AccessibilityDetector.Sighting
        let point: CGPoint
        var id: UUID { sighting.id }
    }

    /// Where each visible find lands on screen for the current camera pose.
    private func placements(in size: CGSize) -> [Placement] {
        guard size.width > 0, size.height > 0, let camera = session.currentFrame?.camera else { return [] }
        let viewFromWorld = camera.transform.inverse
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -Self.margin, dy: -Self.margin)
        return detector.sightings.compactMap { sighting in
            let anchor = sighting.position + SIMD3(0, Self.tagHeight, 0)
            // Skip anything behind the camera, where projection would flip it.
            guard (viewFromWorld * SIMD4(anchor, 1)).z < -0.1 else { return nil }
            let point = camera.projectPoint(anchor, orientation: .portrait, viewportSize: size)
            guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return nil }
            return Placement(sighting: sighting, point: point)
        }
    }
}

/// A capsule with the find's icon and name, in its color, with a short stem down to the spot itself.
private struct FindTag: View {
    /// Taller than any tag, so tags can be bottom-aligned in it.
    static let frameHeight: CGFloat = 80

    let sighting: AccessibilityDetector.Sighting

    var body: some View {
        let tint = sighting.kind.tint
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: sighting.kind.symbolName)
                Text(sighting.isConfirmed ? sighting.name : "\(sighting.name)?")
                    .lineLimit(1)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(sighting.isConfirmed ? 0.95 : 0.7), in: Capsule())
            .overlay {
                if !sighting.isConfirmed {
                    Capsule().strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            Rectangle().fill(tint).frame(width: 2, height: 10)
            Circle().fill(tint).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
