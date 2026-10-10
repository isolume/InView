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
        // Furniture and stairs first, walls over them, doors over the walls, points on top.
        for footprint in map.footprints {
            let symbol = FloorPlanSymbol(footprint: footprint, projection: projection)
            switch footprint.kind {
            case .obstacle: symbol.drawFurniture(in: &context)
            case .stairs: symbol.drawStairs(in: &context)
            case .wall, .door, .opening, .window, .floor: break
            }
        }
        for footprint in map.footprints where footprint.kind == .wall {
            context.fill(projection.path(footprint.corners), with: .color(.primary.opacity(0.85)))
        }
        for footprint in map.footprints where footprint.kind == .door || footprint.kind == .opening {
            FloorPlanSymbol(footprint: footprint, projection: projection).drawDoor(in: &context)
        }

        let start = projection.screenPoint(.zero)
        context.fill(Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)), with: .color(.primary))
        context.draw(Text("Scan start").font(.caption2), at: CGPoint(x: start.x, y: start.y + 8), anchor: .top)

        for point in map.points {
            let center = projection.screenPoint(point.floorPoint)
            let disc = CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26)
            // A white ring keeps the marker readable over walls and furniture.
            context.fill(Path(ellipseIn: disc.insetBy(dx: -2, dy: -2)), with: .color(Color(.systemBackground)))
            context.fill(Path(ellipseIn: disc), with: .color(point.isTooSteep ? .orange : point.kind.tint))
            var symbol = context.resolve(Image(systemName: point.kind.symbolName))
            symbol.shading = .color(.white)
            context.draw(symbol, in: disc.insetBy(dx: 6, dy: 6))
            context.draw(Text(point.name).font(.caption2.weight(.semibold)), at: CGPoint(x: center.x, y: disc.maxY + 3), anchor: .top)
        }
    }
}

/// Draws one footprint as an architectural floor-plan symbol, in the footprint's own axes:
/// x along `size.x`, y along `size.y`.
private struct FloorPlanSymbol {
    let footprint: Footprint
    let projection: MapProjection

    private var half: SIMD2<Float> { footprint.size / 2 }

    func drawFurniture(in context: inout GraphicsContext) {
        let fill = GraphicsContext.Shading.color(.gray.opacity(0.28))
        let ink = GraphicsContext.Shading.color(.gray.opacity(0.8))
        let outline = rectangle(inset: 0)
        switch footprint.furniture {
        case .table:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
        case .chair:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
            // Backrest along the -y edge.
            context.stroke(line(from: [-half.x, -half.y], to: [half.x, -half.y]), with: ink, lineWidth: 3)
        case .sofa:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
            context.fill(strip(y: -half.y, thickness: footprint.size.y * 0.25), with: ink)
            context.fill(strip(x: -half.x, thickness: min(0.18, footprint.size.x * 0.15)), with: ink)
            context.fill(strip(x: half.x - min(0.18, footprint.size.x * 0.15), thickness: min(0.18, footprint.size.x * 0.15)), with: ink)
        case .bed:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
            let pillow = rectangle(from: [-half.x * 0.8, -half.y * 0.95], to: [half.x * 0.8, -half.y * 0.6])
            context.stroke(pillow, with: ink, lineWidth: 1)
        case .toilet:
            let bowl = ellipse(from: [-half.x * 0.8, -half.y * 0.4], to: [half.x * 0.8, half.y])
            context.fill(bowl, with: fill)
            context.stroke(bowl, with: ink, lineWidth: 1)
            context.stroke(rectangle(from: [-half.x, -half.y], to: [half.x, -half.y * 0.45]), with: ink, lineWidth: 1)
        case .sink, .bathtub:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
            context.stroke(ellipse(from: -half * 0.7, to: half * 0.7), with: ink, lineWidth: 1)
        case .appliance:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
            context.stroke(line(from: -half, to: half), with: ink, lineWidth: 0.75)
            context.stroke(line(from: [-half.x, half.y], to: [half.x, -half.y]), with: ink, lineWidth: 0.75)
        case .television:
            context.fill(outline, with: ink)
        case .storage, .fireplace, nil:
            context.fill(outline, with: fill)
            context.stroke(outline, with: ink, lineWidth: 1)
            context.stroke(line(from: -half, to: half), with: ink, lineWidth: 0.75)
        }
    }

    /// Red hatched area with a tread line every 28 cm, like an architectural plan.
    func drawStairs(in context: inout GraphicsContext) {
        let outline = rectangle(inset: 0)
        context.fill(outline, with: .color(Theme.stairs.opacity(0.18)))
        context.stroke(outline, with: .color(Theme.stairs), lineWidth: 1.5)
        var y = -half.y + 0.28
        while y < half.y {
            context.stroke(line(from: [-half.x, y], to: [half.x, y]), with: .color(Theme.stairs.opacity(0.8)), lineWidth: 1)
            y += 0.28
        }
        let center = projection.screenPoint(footprint.center)
        context.draw(Text("Stairs").font(.caption2.bold()).foregroundStyle(Theme.stairs), at: center)
    }

    /// The opening in green (wide enough) or orange (too narrow), plus a swing arc for doors.
    func drawDoor(in context: inout GraphicsContext) {
        let wideEnough = footprint.size.x >= OccupancyGrid.minimumDoorWidth
        let color: Color = wideEnough ? .green : .orange
        context.fill(rectangle(inset: 0), with: .color(color))
        guard footprint.kind == .door else { return }
        var swing = Path()
        let hinge = projection.screenPoint(footprint.floorPoint(local: [-half.x, 0]))
        swing.move(to: projection.screenPoint(footprint.floorPoint(local: [half.x, 0])))
        for step in 1...12 {
            let angle = Float(step) / 12 * .pi / 2
            swing.addLine(to: projection.screenPoint(footprint.floorPoint(local: [-half.x + cos(angle) * footprint.size.x, sin(angle) * footprint.size.x])))
        }
        swing.addLine(to: hinge)
        context.stroke(swing, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    private func rectangle(inset: Float) -> Path {
        rectangle(from: -half + inset, to: half - inset)
    }

    private func rectangle(from low: SIMD2<Float>, to high: SIMD2<Float>) -> Path {
        polygon([low, [high.x, low.y], high, [low.x, high.y]])
    }

    private func strip(y: Float, thickness: Float) -> Path {
        rectangle(from: [-half.x, y], to: [half.x, y + thickness])
    }

    private func strip(x: Float, thickness: Float) -> Path {
        rectangle(from: [x, -half.y], to: [x + thickness, half.y])
    }

    private func ellipse(from low: SIMD2<Float>, to high: SIMD2<Float>) -> Path {
        let center = (low + high) / 2, radius = (high - low) / 2
        return polygon((0..<24).map { step in
            let angle = Float(step) / 24 * 2 * .pi
            return center + SIMD2(cos(angle), sin(angle)) * radius
        })
    }

    private func line(from a: SIMD2<Float>, to b: SIMD2<Float>) -> Path {
        Path { path in
            path.move(to: projection.screenPoint(footprint.floorPoint(local: a)))
            path.addLine(to: projection.screenPoint(footprint.floorPoint(local: b)))
        }
    }

    private func polygon(_ local: [SIMD2<Float>]) -> Path {
        projection.path(local.map(footprint.floorPoint(local:)))
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
