import AccessCore
import simd
import SwiftUI

/// Top-down drawing of a venue map. Tapping reports the venue floor point under the finger.
struct MapPreviewView: View {
    let map: VenueMap
    var onTap: ((SIMD2<Float>) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let projection = MapProjection(map: map, size: geometry.size)
            Canvas { context, _ in draw(in: &context, projection: projection) }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    onTap?(projection.venuePoint(location))
                }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Floor plan with \(map.points.count) accessible points")
    }

    private func draw(in context: inout GraphicsContext, projection: MapProjection) {
        for footprint in map.footprints {
            let shape = projection.path(footprint.corners)
            switch footprint.kind {
            case .obstacle: context.fill(shape, with: .color(.gray.opacity(0.35)))
            case .stairs: context.fill(shape, with: .color(.red.opacity(0.6)))
            case .wall: context.fill(shape, with: .color(.primary))
            case .door, .opening: break
            }
        }
        // Doors last so they cut visibly through the walls.
        for footprint in map.footprints where footprint.kind == .door || footprint.kind == .opening {
            let wideEnough = footprint.size.x >= OccupancyGrid.minimumDoorWidth
            context.fill(projection.path(footprint.corners), with: .color(wideEnough ? .green : .orange))
        }

        let marker = projection.screenPoint(.zero)
        context.fill(Path(CGRect(x: marker.x - 5, y: marker.y - 5, width: 10, height: 10)), with: .color(.primary))
        context.draw(Text("Check-in").font(.caption2), at: CGPoint(x: marker.x, y: marker.y + 8), anchor: .top)

        for point in map.points {
            let center = projection.screenPoint(point.floorPoint)
            let disc = CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)
            context.fill(Path(ellipseIn: disc), with: .color(point.kind.tint))
            var symbol = context.resolve(Image(systemName: point.kind.symbolName))
            symbol.shading = .color(.white)
            context.draw(symbol, in: disc.insetBy(dx: 6, dy: 6))
        }
    }
}

/// Fits the venue floor into the view: venue x runs right, venue z runs down.
private struct MapProjection {
    private let minimum: SIMD2<Float>
    private let scale: CGFloat
    private let offset: CGPoint

    init(map: VenueMap, size: CGSize, inset: CGFloat = 20) {
        var lower = SIMD2<Float>(-0.5, -0.5)
        var upper = SIMD2<Float>(0.5, 0.5)
        for point in map.footprints.flatMap(\.corners) + map.points.map(\.floorPoint) {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        let span = upper - lower
        let available = CGSize(width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
        scale = min(available.width / CGFloat(span.x), available.height / CGFloat(span.y))
        minimum = lower
        offset = CGPoint(
            x: inset + (available.width - CGFloat(span.x) * scale) / 2,
            y: inset + (available.height - CGFloat(span.y) * scale) / 2
        )
    }

    func screenPoint(_ point: SIMD2<Float>) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(point.x - minimum.x) * scale, y: offset.y + CGFloat(point.y - minimum.y) * scale)
    }

    func venuePoint(_ point: CGPoint) -> SIMD2<Float> {
        SIMD2(minimum.x + Float((point.x - offset.x) / scale), minimum.y + Float((point.y - offset.y) / scale))
    }

    func path(_ corners: [SIMD2<Float>]) -> Path {
        Path { path in
            path.addLines(corners.map(screenPoint))
            path.closeSubpath()
        }
    }
}
