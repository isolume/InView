import AccessCore
import simd
import SwiftUI

/// Top-down drawing of a venue map, styled like an architectural plan: a faint metre grid on paper,
/// each room's floor filled, charcoal walls with door swings and windows, tinted furniture symbols,
/// hatched stairs, pins for the accessible points, and a scale bar.
/// Tapping reports the venue floor point under the finger. Pinch to zoom; once zoomed, drag to move around.
struct MapPreviewView: View {
    let map: VenueMap
    var route: Route? = nil
    var userPosition: SIMD2<Float>? = nil
    var userHeading: Float = 0
    var showsScanStart = true
    /// Pins to draw instead of the map's own points, such as live places found nearby.
    var places: [MapPlace]? = nil
    /// Room kept clear for controls and panels over the plan. The paper and grid still fill the view.
    var contentInsets = EdgeInsets()
    /// Changing it shows the whole floor again.
    var resetID = 0
    var cornerRadius = Theme.Radius.control
    var showsFitButton = true
    var onTap: ((SIMD2<Float>) -> Void)?
    /// A tap on a pin; without `onTap`, taps elsewhere are ignored.
    var onSelectPlace: ((MapPlace) -> Void)? = nil
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maximumZoom: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let liveZoom = min(Self.maximumZoom, max(1, zoom * pinch))
            let livePan = clamped(CGSize(width: pan.width + drag.width, height: pan.height + drag.height), zoom: liveZoom, in: geometry.size)
            let projection = MapProjection(map: map, size: geometry.size, zoom: liveZoom, pan: livePan,
                                           extra: displayedPlaces.map(\.position), insets: contentInsets)
            Canvas { context, size in
                draw(in: &context, size: size, projection: projection)
            } symbols: {
                // The same badge the lists, the 3D map and the surroundings map use.
                ForEach(displayedPlaces) { place in
                    KindBadge(symbol: place.symbol, tint: place.tint, size: KindBadge.mapDiameter, isOnMap: true)
                        .tag(place.id)
                }
            }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    // Choosing a start point takes every tap; otherwise a tap picks the pin under it.
                    if let onTap { onTap(projection.venuePoint(location)); return }
                    func distance(_ place: MapPlace) -> CGFloat {
                        let point = projection.screenPoint(place.position)
                        return hypot(point.x - location.x, point.y - location.y)
                    }
                    let reach = KindBadge.mapDiameter / 2 + KindBadge.ringWidth + 8
                    if let hit = displayedPlaces.min(by: { distance($0) < distance($1) }), distance(hit) <= reach {
                        onSelectPlace?(hit)
                    }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            zoom = min(Self.maximumZoom, max(1, zoom * value.magnification))
                            pan = clamped(pan, zoom: zoom, in: geometry.size)
                        }
                )
                // At full size the plan doesn't move, so a drag still scrolls whatever it sits in.
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            pan = clamped(CGSize(width: pan.width + value.translation.width, height: pan.height + value.translation.height),
                                          zoom: zoom, in: geometry.size)
                        },
                    including: zoom > 1 ? .all : .subviews
                )
                .overlay(alignment: .topTrailing) {
                    if zoom > 1, showsFitButton {
                        Button("Show whole floor", systemImage: "arrow.down.right.and.arrow.up.left") {
                            withAnimation(.smooth) { zoom = 1; pan = .zero }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.smooth, value: zoom > 1)
        }
        .background(PlanInk.paper, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onChange(of: resetID) { _, _ in withAnimation(.smooth) { zoom = 1; pan = .zero } }
        .accessibilityLabel("Floor plan with \(displayedPlaces.count) places")
        .accessibilityZoomAction { action in
            zoom = min(Self.maximumZoom, max(1, action.direction == .zoomIn ? zoom * 1.5 : zoom / 1.5))
            if zoom == 1 { pan = .zero }
        }
        .accessibilityValue(route.map { "Route to \($0.destination.title), \(Int($0.length.rounded())) meters" } ?? "")
    }

    private var displayedPlaces: [MapPlace] { places ?? map.points.map(MapPlace.init) }

    /// Keeps the zoomed plan from sliding off the view.
    private func clamped(_ pan: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        let limit = CGSize(width: size.width * (zoom - 1) / 2, height: size.height * (zoom - 1) / 2)
        return CGSize(width: min(limit.width, max(-limit.width, pan.width)),
                      height: min(limit.height, max(-limit.height, pan.height)))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, projection: MapProjection) {
        drawGrid(in: &context, size: size, projection: projection)

        let floors = map.footprints.filter { $0.kind == .floor }
        for floor in floors {
            let outline = projection.path(floor.corners)
            context.fill(outline, with: .color(PlanInk.floor))
            context.stroke(outline, with: .color(PlanInk.floorEdge), lineWidth: 1.5)
        }

        // Rooms named by a sign, tinted under everything else on the floor.
        for place in displayedPlaces {
            guard let area = place.area else { continue }
            let outline = projection.path(area.outline)
            if area.isMeasured {
                context.fill(outline, with: .color(place.tint.opacity(0.16)))
                context.stroke(outline, with: .color(place.tint.opacity(0.8)), lineWidth: 1.5)
            } else if let door = place.door {
                // A fan fading away from the doorway: the room is there, just not measured.
                let start = projection.screenPoint(door.center)
                let end = projection.screenPoint(area.outline[2] / 2 + area.outline[3] / 2)
                context.fill(outline, with: .linearGradient(Gradient(colors: [place.tint.opacity(0.3), place.tint.opacity(0)]),
                                                            startPoint: start, endPoint: end))
            }
        }

        // Furniture and stairs on the floor, walls over them, openings and windows over the walls, points on top.
        for footprint in map.footprints {
            let symbol = FloorPlanSymbol(footprint: footprint, projection: projection)
            switch footprint.kind {
            case .obstacle: symbol.drawFurniture(in: &context)
            case .stairs: symbol.drawStairs(in: &context)
            case .wall, .door, .opening, .window, .floor: break
            }
        }
        for footprint in map.footprints where footprint.kind == .wall {
            // Stroked as well as filled, so thin measured walls still read as walls when zoomed out.
            let wall = projection.path(footprint.corners)
            context.fill(wall, with: .color(PlanInk.wall))
            context.stroke(wall, with: .color(PlanInk.wall), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        for footprint in map.footprints where footprint.kind == .window {
            FloorPlanSymbol(footprint: footprint, projection: projection).drawWindow(in: &context)
        }
        for footprint in map.footprints where footprint.kind == .door || footprint.kind == .opening {
            FloorPlanSymbol(footprint: footprint, projection: projection).drawDoor(in: &context)
        }

        // The doorway each sign labeled, as a bright threshold across the wall gap.
        for place in displayedPlaces {
            guard let (a, b) = place.doorEnds else { continue }
            let threshold = Path { $0.addLines([projection.screenPoint(a), projection.screenPoint(b)]) }
            context.stroke(threshold, with: .color(.white), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.stroke(threshold, with: .color(place.tint), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
        }

        if showsScanStart {
            let start = projection.screenPoint(.zero)
            context.fill(Path(ellipseIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12)), with: .color(PlanInk.paper))
            context.fill(Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)), with: .color(PlanInk.wall))
            context.draw(Text("Scan start").font(.caption2).foregroundStyle(PlanInk.annotation), at: CGPoint(x: start.x, y: start.y + 8), anchor: .top)
        }
        if let route, route.waypoints.count > 1 {
            let path = Path { $0.addLines(route.waypoints.map(projection.screenPoint)) }
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(Theme.route), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        if let userPosition {
            let center = projection.screenPoint(userPosition)
            let cone = Path { path in
                path.move(to: center)
                for index in 0...20 {
                    let angle = CGFloat(userHeading) - .pi / 6 + CGFloat(index) * .pi / 60
                    path.addLine(to: CGPoint(x: center.x + sin(angle) * 30, y: center.y - cos(angle) * 30))
                }
                path.closeSubpath()
            }
            context.fill(cone, with: .color(Theme.route.opacity(0.15)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)), with: .color(.white))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)), with: .color(Theme.route))
        }

        drawPlaces(in: &context, projection: projection)
        drawScaleBar(in: &context, size: size, projection: projection)
    }

    /// Badges first, then the names that fit, like Apple Maps: a name goes below its badge, or beside or above
    /// it, and is left off rather than cover another place. Stairs and room areas fill in where there's room.
    private func drawPlaces(in context: inout GraphicsContext, projection: MapProjection) {
        let radius = KindBadge.mapDiameter / 2 + KindBadge.ringWidth
        let destination = route?.destination.id
        let places = displayedPlaces.sorted { ($0.id == destination ? 0 : 1) < ($1.id == destination ? 0 : 1) }
        var occupied: [CGRect] = []
        for point in places {
            let center = projection.screenPoint(point.position)
            guard let badge = context.resolveSymbol(id: point.id) else { continue }
            context.draw(badge, at: center)
            occupied.append(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }

        /// Around a badge `clearance` from `center`, or on `center` itself when there's no clearance.
        func place(_ text: Text, near center: CGPoint, clearance: CGFloat?, plate: Bool) {
            let label = context.resolve(text)
            let measured = label.measure(in: CGSize(width: 160, height: 40))
            let size = CGSize(width: measured.width + 8, height: measured.height + 2)
            let origins = clearance.map { clearance in [
                CGPoint(x: center.x - size.width / 2, y: center.y + clearance + 2),
                CGPoint(x: center.x + clearance + 2, y: center.y - size.height / 2),
                CGPoint(x: center.x - clearance - 2 - size.width, y: center.y - size.height / 2),
                CGPoint(x: center.x - size.width / 2, y: center.y - clearance - 2 - size.height),
            ] } ?? [CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)]
            let candidates = origins.map { CGRect(origin: $0, size: size) }
            guard let frame = candidates.first(where: { candidate in !occupied.contains { $0.intersects(candidate) } }) else { return }
            occupied.append(frame)
            if plate { context.fill(Path(roundedRect: frame, cornerRadius: 4), with: .color(PlanInk.paper.opacity(0.85))) }
            context.draw(label, at: CGPoint(x: frame.midX, y: frame.midY))
        }

        for point in places {
            place(Text(point.title).font(.caption.weight(.semibold)).foregroundStyle(PlanInk.label),
                  near: projection.screenPoint(point.position), clearance: radius, plate: true)
        }
        for stairs in map.footprints where stairs.kind == .stairs {
            place(Text("Stairs").font(.caption2.bold()).foregroundStyle(Theme.stairs),
                  near: projection.screenPoint(stairs.center), clearance: nil, plate: false)
        }
        for floor in map.footprints where floor.kind == .floor {
            let area = abs(Polygon.signedArea(floor.corners))
            guard area >= 6, projection.scale * CGFloat(floor.size.x.squareRoot()) > 60 else { continue }
            place(Text(String(format: "%.0f m²", area)).font(.caption2).foregroundStyle(PlanInk.annotation),
                  near: projection.screenPoint(floor.center), clearance: nil, plate: false)
        }
    }

    /// Faint lines every metre (or every 2 or 5 m when zoomed out), like graph paper.
    private func drawGrid(in context: inout GraphicsContext, size: CGSize, projection: MapProjection) {
        let spacing: Float = projection.scale >= 24 ? 1 : projection.scale >= 10 ? 2 : 5
        let lower = projection.venuePoint(.zero), upper = projection.venuePoint(CGPoint(x: size.width, y: size.height))
        var grid = Path()
        var x = (lower.x / spacing).rounded(.down) * spacing
        while x <= upper.x {
            let sx = projection.screenPoint(SIMD2(x, 0)).x
            grid.move(to: CGPoint(x: sx, y: 0))
            grid.addLine(to: CGPoint(x: sx, y: size.height))
            x += spacing
        }
        var z = (lower.y / spacing).rounded(.down) * spacing
        while z <= upper.y {
            let sy = projection.screenPoint(SIMD2(0, z)).y
            grid.move(to: CGPoint(x: 0, y: sy))
            grid.addLine(to: CGPoint(x: size.width, y: sy))
            z += spacing
        }
        context.stroke(grid, with: .color(PlanInk.grid), lineWidth: 0.5)
    }

    private func drawScaleBar(in context: inout GraphicsContext, size: CGSize, projection: MapProjection) {
        let meters: Float = projection.scale >= 60 ? 1 : projection.scale >= 25 ? 2 : 5
        let length = CGFloat(meters) * projection.scale
        guard length < (size.width - contentInsets.leading) / 2 else { return }
        let origin = CGPoint(x: contentInsets.leading + 12, y: size.height - contentInsets.bottom - 14)
        var bar = Path()
        bar.move(to: origin)
        bar.addLine(to: CGPoint(x: origin.x + length, y: origin.y))
        for x in [origin.x, origin.x + length] {
            bar.move(to: CGPoint(x: x, y: origin.y - 4))
            bar.addLine(to: CGPoint(x: x, y: origin.y + 4))
        }
        context.stroke(bar, with: .color(PlanInk.annotation), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        context.draw(
            Text("\(Int(meters)) m").font(.caption2.weight(.medium)).foregroundStyle(PlanInk.annotation),
            at: CGPoint(x: origin.x + length / 2, y: origin.y - 6),
            anchor: .bottom
        )
    }
}

/// The plan's palette, with dark-mode versions, so it reads like a drawing in either appearance.
enum PlanInk {
    static let paper = dynamic(light: UIColor(red: 0.985, green: 0.975, blue: 0.955, alpha: 1), dark: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
    static let grid = dynamic(light: UIColor(white: 0, alpha: 0.07), dark: UIColor(white: 1, alpha: 0.07))
    static let floor = dynamic(light: UIColor(red: 0.96, green: 0.93, blue: 0.87, alpha: 1), dark: UIColor(red: 0.2, green: 0.19, blue: 0.17, alpha: 1))
    static let floorEdge = dynamic(light: UIColor(red: 0.85, green: 0.8, blue: 0.72, alpha: 1), dark: UIColor(red: 0.32, green: 0.3, blue: 0.27, alpha: 1))
    static let wall = dynamic(light: UIColor(white: 0.16, alpha: 1), dark: UIColor(white: 0.88, alpha: 1))
    static let window = dynamic(light: UIColor(red: 0.55, green: 0.8, blue: 0.95, alpha: 1), dark: UIColor(red: 0.45, green: 0.7, blue: 0.9, alpha: 1))
    static let annotation = dynamic(light: UIColor(white: 0.35, alpha: 1), dark: UIColor(white: 0.7, alpha: 1))
    static let label = Color.primary
    /// Furniture fills: wood, fabric, porcelain, steel; each with a darker ink for its outline.
    static let wood = dynamic(light: UIColor(red: 0.87, green: 0.76, blue: 0.62, alpha: 1), dark: UIColor(red: 0.45, green: 0.36, blue: 0.27, alpha: 1))
    static let fabric = dynamic(light: UIColor(red: 0.75, green: 0.8, blue: 0.88, alpha: 1), dark: UIColor(red: 0.33, green: 0.38, blue: 0.47, alpha: 1))
    static let porcelain = dynamic(light: UIColor(white: 0.97, alpha: 1), dark: UIColor(white: 0.6, alpha: 1))
    static let steel = dynamic(light: UIColor(white: 0.78, alpha: 1), dark: UIColor(white: 0.45, alpha: 1))
    static let ink = dynamic(light: UIColor(white: 0.25, alpha: 0.75), dark: UIColor(white: 0.9, alpha: 0.6))
    static let shadow = dynamic(light: UIColor(white: 0, alpha: 0.12), dark: UIColor(white: 0, alpha: 0.35))

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Draws one footprint as an architectural floor-plan symbol, in the footprint's own axes:
/// x along `size.x`, y along `size.y`.
private struct FloorPlanSymbol {
    let footprint: Footprint
    let projection: MapProjection

    private var half: SIMD2<Float> { footprint.size / 2 }

    func drawFurniture(in context: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(PlanInk.ink)
        let outline = rectangle(inset: 0)
        // A soft shadow lifts each piece off the floor.
        var shadow = context
        shadow.translateBy(x: 1.5, y: 2)
        shadow.fill(outline, with: .color(PlanInk.shadow))

        switch footprint.furniture {
        case .table:
            context.fill(outline, with: .color(PlanInk.wood))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            context.stroke(rectangle(inset: min(0.1, footprint.size.min() * 0.15)), with: ink, lineWidth: 1)
        case .chair:
            context.fill(outline, with: .color(PlanInk.fabric))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            // Backrest along the -y edge.
            context.fill(strip(y: -half.y, thickness: min(0.08, footprint.size.y * 0.2)), with: ink)
        case .sofa:
            context.fill(outline, with: .color(PlanInk.fabric))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            let arm = min(0.18, footprint.size.x * 0.15)
            context.fill(strip(y: -half.y, thickness: footprint.size.y * 0.25), with: ink)
            context.fill(strip(x: -half.x, thickness: arm), with: ink)
            context.fill(strip(x: half.x - arm, thickness: arm), with: ink)
            // Seat cushions.
            let cushions = max(1, Int((footprint.size.x / 0.7).rounded()))
            for i in 1..<max(2, cushions) {
                let x = -half.x + arm + (footprint.size.x - 2 * arm) * Float(i) / Float(cushions)
                context.stroke(line(from: [x, -half.y + footprint.size.y * 0.25], to: [x, half.y]), with: ink, lineWidth: 1)
            }
        case .bed:
            context.fill(outline, with: .color(PlanInk.porcelain))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            let pillow = rectangle(from: [-half.x * 0.8, -half.y * 0.95], to: [half.x * 0.8, -half.y * 0.6])
            context.stroke(pillow, with: ink, lineWidth: 1.75)
            context.stroke(line(from: [-half.x, -half.y * 0.45], to: [half.x, -half.y * 0.45]), with: ink, lineWidth: 1.25)
        case .toilet:
            let bowl = ellipse(from: [-half.x * 0.8, -half.y * 0.4], to: [half.x * 0.8, half.y])
            context.fill(bowl, with: .color(PlanInk.porcelain))
            context.stroke(bowl, with: ink, lineWidth: 1.75)
            let tank = rectangle(from: [-half.x, -half.y], to: [half.x, -half.y * 0.45])
            context.fill(tank, with: .color(PlanInk.porcelain))
            context.stroke(tank, with: ink, lineWidth: 1.75)
        case .sink, .bathtub:
            context.fill(outline, with: .color(PlanInk.porcelain))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            context.stroke(ellipse(from: -half * 0.7, to: half * 0.7), with: ink, lineWidth: 1.75)
        case .appliance:
            context.fill(outline, with: .color(PlanInk.steel))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            context.stroke(line(from: -half, to: half), with: ink, lineWidth: 1)
            context.stroke(line(from: [-half.x, half.y], to: [half.x, -half.y]), with: ink, lineWidth: 1)
        case .television:
            context.fill(outline, with: ink)
        case .storage, .fireplace, nil:
            context.fill(outline, with: .color(PlanInk.wood))
            context.stroke(outline, with: ink, lineWidth: 1.75)
            context.stroke(line(from: -half, to: half), with: ink, lineWidth: 1)
            context.stroke(line(from: [-half.x, half.y], to: [half.x, -half.y]), with: ink, lineWidth: 1)
        }
    }

    /// Red hatched area with a tread line every 28 cm and an arrow up the flight, like an architectural plan.
    func drawStairs(in context: inout GraphicsContext) {
        let outline = rectangle(inset: 0)
        context.fill(outline, with: .color(Theme.stairs.opacity(0.18)))
        context.stroke(outline, with: .color(Theme.stairs), lineWidth: 1.5)
        var y = -half.y + 0.28
        while y < half.y {
            context.stroke(line(from: [-half.x, y], to: [half.x, y]), with: .color(Theme.stairs.opacity(0.8)), lineWidth: 1.75)
            y += 0.28
        }
        // Direction of climb: up the footprint's y axis.
        var arrow = Path()
        arrow.move(to: projection.screenPoint(footprint.floorPoint(local: [0, -half.y + 0.15])))
        arrow.addLine(to: projection.screenPoint(footprint.floorPoint(local: [0, half.y - 0.15])))
        let head: Float = min(0.15, footprint.size.x * 0.2)
        arrow.move(to: projection.screenPoint(footprint.floorPoint(local: [-head, half.y - 0.15 - head])))
        arrow.addLine(to: projection.screenPoint(footprint.floorPoint(local: [0, half.y - 0.15])))
        arrow.addLine(to: projection.screenPoint(footprint.floorPoint(local: [head, half.y - 0.15 - head])))
        context.stroke(arrow, with: .color(Theme.stairs), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    /// A gap in the wall, a leaf swung open on its hinge, and the swing arc; green when wide enough for a chair, orange when not.
    func drawDoor(in context: inout GraphicsContext) {
        let wideEnough = footprint.size.x >= OccupancyGrid.minimumDoorWidth
        let color = Theme.color(for: wideEnough ? .good : .warning)
        context.fill(rectangle(inset: 0), with: .color(PlanInk.floor))
        // Thin jambs either side of the gap.
        context.fill(rectangle(from: [-half.x - 0.03, -half.y], to: [-half.x, half.y]), with: .color(PlanInk.wall))
        context.fill(rectangle(from: [half.x, -half.y], to: [half.x + 0.03, half.y]), with: .color(PlanInk.wall))
        guard footprint.kind == .door else {
            // An opening: just mark its width.
            context.stroke(line(from: [-half.x, 0], to: [half.x, 0]), with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            return
        }
        let width = footprint.size.x
        var leaf = Path()
        leaf.move(to: projection.screenPoint(footprint.floorPoint(local: [-half.x, 0])))
        leaf.addLine(to: projection.screenPoint(footprint.floorPoint(local: [-half.x, width])))
        context.stroke(leaf, with: .color(color), lineWidth: 2)
        var swing = Path()
        swing.move(to: projection.screenPoint(footprint.floorPoint(local: [half.x, 0])))
        for step in 1...12 {
            let angle = Float(step) / 12 * .pi / 2
            swing.addLine(to: projection.screenPoint(footprint.floorPoint(local: [-half.x + cos(angle) * width, sin(angle) * width])))
        }
        context.stroke(swing, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }

    /// A pale band in the wall with a centre line, the usual plan symbol for glazing.
    func drawWindow(in context: inout GraphicsContext) {
        context.fill(rectangle(inset: 0), with: .color(PlanInk.window))
        context.stroke(line(from: [-half.x, 0], to: [half.x, 0]), with: .color(PlanInk.wall), lineWidth: 1.75)
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
    /// Screen points per metre.
    let scale: CGFloat
    private let offset: CGPoint

    /// `zoom` scales about the view's center and `pan` then moves the plan, both in screen points.
    /// `insets` is room covered by controls: the floor is fitted, and zoomed, within what's left.
    init(map: VenueMap, size: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero, inset: CGFloat = 24,
         extra: [SIMD2<Float>] = [], insets: EdgeInsets = EdgeInsets()) {
        var lower = SIMD2<Float>(-0.5, -0.5)
        var upper = SIMD2<Float>(0.5, 0.5)
        for point in map.footprints.flatMap(\.corners) + map.points.map(\.floorPoint) + extra {
            lower = simd_min(lower, point)
            upper = simd_max(upper, point)
        }
        let span = upper - lower
        let available = CGSize(width: max(1, size.width - insets.leading - insets.trailing - 2 * inset),
                               height: max(1, size.height - insets.top - insets.bottom - 2 * inset))
        let fitted = min(available.width / CGFloat(span.x), available.height / CGFloat(span.y))
        let origin = CGPoint(
            x: insets.leading + inset + (available.width - CGFloat(span.x) * fitted) / 2,
            y: insets.top + inset + (available.height - CGFloat(span.y) * fitted) / 2
        )
        let middle = CGPoint(x: insets.leading + inset + available.width / 2, y: insets.top + inset + available.height / 2)
        scale = fitted * zoom
        minimum = lower
        offset = CGPoint(x: middle.x + (origin.x - middle.x) * zoom + pan.width,
                         y: middle.y + (origin.y - middle.y) * zoom + pan.height)
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
