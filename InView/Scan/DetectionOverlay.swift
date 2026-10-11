import ARKit
import AccessCore
import SwiftUI

/// Pins a small colored tag over every find, on the live scanning camera: blue elevators, teal ramps, red
/// stairs. Tags are dashed and end in "?" while a find is still being confirmed.
///
/// Refreshes at 10 Hz, projecting only a bounded set of nearby finds even in a large building scan.
struct DetectionOverlay: View {
    @ObservedObject var detector: AccessibilityDetector
    let session: ARSession
    var signs: [CaptureTextObservation] = []

    /// Tags sit this far above the floor spot, so they don't cover the find itself.
    private static let tagHeight: Float = 0.3
    private static let refreshInterval: TimeInterval = 0.1
    /// Finds whose projection is this far outside the screen aren't laid out.
    private static let margin: CGFloat = 60

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(signPlacements(in: geometry.size)) { placement in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placement.observation.text).font(.caption.weight(.bold)).lineLimit(2)
                            Text("\(placement.spatial.meaning.kind.rawValue.capitalized) sign · unverified destination")
                                .font(.system(size: 9))
                            Text(String(format: "x %.2f  y %.2f  z %.2f m", placement.spatial.x, placement.spatial.y, placement.spatial.z))
                                .font(.system(size: 9, design: .monospaced))
                            if let height = placement.spatial.heightAboveFloorM {
                                Text(String(format: "%.2f m above measured floor", height)).font(.system(size: 9))
                            }
                        }
                        .foregroundStyle(.white).padding(7).frame(maxWidth: 215)
                        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.mint.opacity(0.8)))
                        .position(placement.point)
                    }
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

    private struct SignPlacement: Identifiable {
        let id: Int
        let observation: CaptureTextObservation
        let spatial: SpatialSign
        let point: CGPoint
    }

    private func signPlacements(in size: CGSize) -> [SignPlacement] {
        guard size.width > 0, size.height > 0, let frame = session.currentFrame,
              case .normal = frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime - frame.timestamp) < 1 else { return [] }
        let camera = frame.camera
        let inverse = camera.transform.inverse
        var result: [SignPlacement] = []
        let recent = signs.enumerated().reversed()
        for (index, observation) in recent {
            guard let spatial = observation.spatial,
                  simd_distance(camera.transform.translation, spatial.position) < 15,
                  (inverse * SIMD4(spatial.position, 1)).z < -0.1,
                  !result.contains(where: { $0.observation.text.caseInsensitiveCompare(observation.text) == .orderedSame
                      && simd_distance($0.spatial.position, spatial.position) < 1 }) else { continue }
            let point = camera.projectPoint(spatial.position, orientation: .portrait, viewportSize: size)
            guard point.x.isFinite, point.y.isFinite, CGRect(origin: .zero, size: size).contains(point) else { continue }
            result.append(SignPlacement(id: index, observation: observation, spatial: spatial, point: point))
            if result.count == 10 { break }
        }
        return result
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
        return detector.nearbySightings(to: camera.transform.translation).compactMap { sighting in
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
