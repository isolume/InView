import AccessCore
import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit
import simd

/// Both the exterior and cutaway use Mapbox's renderer, camera and depth buffer.
/// No transparent SceneKit view is composed over the outdoor map.
struct GeographicMapboxView: View {
    let scene: ProcessedScene?
    let map: VenueMap
    let reference: BuildingMapReference
    let accessToken: String?
    let routePoints: [SIMD2<Float>]
    let userPosition: SIMD2<Float>?
    let destination: SIMD2<Float>?
    let destinationTitle: String?
    let topDown: Bool
    let resetID: Int
    let bottomInset: CGFloat
    var groundFloorY: Float? = nil

    @State private var showsLocalPreview = false
    @State private var cutawayUnavailable = false

    private var publicToken: String? {
        if ProcessInfo.processInfo.arguments.contains("--mapbox-local-preview") { return nil }
        guard let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              token.hasPrefix("pk."), token.count > 3 else { return nil }
        return token
    }

    var body: some View {
        if publicToken != nil || showsLocalPreview {
            GeographicMapboxCanvas(scene: scene, map: map, reference: reference,
                                   accessToken: publicToken, routePoints: routePoints,
                                   userPosition: userPosition, destination: destination,
                                   destinationTitle: destinationTitle, topDown: topDown,
                                   resetID: resetID, bottomInset: bottomInset, groundFloorY: groundFloorY,
                                   cutawayUnavailable: $cutawayUnavailable)
                .id(publicToken == nil ? "interior-preview" : "outdoor-map")
                .overlay(alignment: .top) {
                    if publicToken == nil {
                        StatusPill(text: "Local preview · Example exterior", isCompact: true)
                            .padding(.top, 122)
                            .allowsHitTesting(false)
                    } else if cutawayUnavailable {
                        StatusPill(text: "Interior cutaway unavailable", systemImage: "exclamationmark.circle", isCompact: true)
                            .padding(.top, 122)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            ContentUnavailableView {
                Label("Surroundings unavailable", systemImage: "map")
            } description: {
                Text("You can still preview the indoor map.")
            } actions: {
                Button("Preview interior") { showsLocalPreview = true }
                    .buttonStyle(.glassProminent)
            }
            .padding(.bottom, bottomInset)
        }
    }
}

private struct GeographicMapboxCanvas: UIViewRepresentable {
    let scene: ProcessedScene?
    let map: VenueMap
    let reference: BuildingMapReference
    let accessToken: String?
    let routePoints: [SIMD2<Float>]
    let userPosition: SIMD2<Float>?
    let destination: SIMD2<Float>?
    let destinationTitle: String?
    let topDown: Bool
    let resetID: Int
    let bottomInset: CGFloat
    let groundFloorY: Float?
    @Binding var cutawayUnavailable: Bool
    /// Rendered here, on the main actor, for the coordinator's style content.
    let destinationBadge = KindBadge.image(symbol: AccessPoint.Kind.destination.symbolName, tint: Theme.accent)

    func makeUIView(context: Context) -> GeographicMapboxContainer {
        if let accessToken { MapboxOptions.accessToken = accessToken }
        let origin = CLLocationCoordinate2D(latitude: reference.latitude, longitude: reference.longitude)
        let options = MapInitOptions(
            mapStyle: accessToken == nil ? Self.localStyle : InViewMapboxStyle.outdoor,
            cameraOptions: CameraOptions(center: origin, zoom: 19.5,
                                         bearing: reference.headingDegrees + 35,
                                         pitch: topDown ? 0 : 50),
            antialiasingSampleCount: 4)
        let container = GeographicMapboxContainer(options: options)
        context.coordinator.container = container
        context.coordinator.installEvents()
        container.onLayout = { [weak coordinator = context.coordinator] in coordinator?.fitIfNeeded() }
        context.coordinator.update(self)
        return container
    }

    func updateUIView(_ uiView: GeographicMapboxContainer, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIView(_ uiView: GeographicMapboxContainer, coordinator: Coordinator) {
        uiView.onLayout = nil
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // A complete style with only an inline import: no tile URLs, glyphs, remote
    // images or borrowed account token. The larger example building is in the
    // same renderer as live buildings, exercising polygon subtraction.
    static func localExteriorOutline(_ geometry: GeographicMapboxGeometry) -> [SIMD2<Float>] {
        let reference = geometry.reference
        let points = geometry.fitCoordinates.compactMap {
            try? reference.mapPoint(for: .init(latitude: $0.latitude, longitude: $0.longitude))
        }
        let first = points.first ?? .zero
        let lower = points.reduce(first, simd_min) - SIMD2<Float>(repeating: 4)
        let upper = points.reduce(first, simd_max) + SIMD2<Float>(repeating: 8)
        return [lower, SIMD2(upper.x, lower.y), upper, SIMD2(lower.x, upper.y)]
    }

    static let localStyle: MapStyle = {
        let basemap: [String: Any] = [
            "version": 8, "sources": [:],
            "layers": [["id": "example-ground", "type": "background",
                        "paint": ["background-color": "#e9ece8"]]]
        ]
        let style: [String: Any] = [
            "version": 8, "sources": [:], "layers": [],
            "imports": [["id": "basemap", "data": basemap, "url": ""]],
            "light": ["anchor": "viewport", "color": "#ffffff", "intensity": 0.35, "position": [1.5, 210, 35]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: style),
              let json = String(data: data, encoding: .utf8) else { return .empty }
        return MapStyle(json: json)
    }()


    final class Coordinator {
        weak var container: GeographicMapboxContainer?
        private var content: GeographicMapboxCanvas?
        private var geometry: GeographicMapboxGeometry?
        private var sourceScene: ProcessedScene?
        private var sourceReference: BuildingMapReference?
        private var sourceFootprints: [Footprint] = []
        private var sourceFloorY: Float?
        private var lastResetID: Int?
        private var lastTopDown: Bool?
        private var fitPending = true
        private var localExteriorOutline: [SIMD2<Float>]?
        private var exteriorCutaway: GeographicMapboxGeometry.ExteriorCutaway?
        private var exteriorQuery: Cancelable?
        private var idleObservation: AnyCancelable?
        private var queryGeneration = 0
        private var requestedExterior = false

        func installEvents() {
            guard let container else { return }
            idleObservation = container.mapView.mapboxMap.onMapIdle.observe { [weak self] _ in
                self?.prepareExteriorIfNeeded()
            }
        }

        func stop() {
            exteriorQuery?.cancel()
            idleObservation?.cancel()
            container = nil
        }

        private func prepareExteriorIfNeeded() {
            guard !requestedExterior, let container, let content, let geometry,
                  content.accessToken != nil, !geometry.floorPolygons.isEmpty else { return }
            requestedExterior = true
            let generation = queryGeneration
            exteriorQuery = container.mapView.mapboxMap.queryRenderedFeatures(featureset: .standardBuildings) { [weak self] result in
                guard let self, generation == self.queryGeneration,
                      let content = self.content, let geometry = self.geometry else { return }
                self.exteriorQuery = nil
                // Never hide an original feature unless its queried source
                // geometry and height yielded a valid untouched remainder.
                do {
                    let buildings = try result.get()
                    let cutaway = try geometry.cutaway(buildings: buildings)
                    content.cutawayUnavailable = false
                    if !cutaway.clip.features.isEmpty {
                        self.exteriorCutaway = cutaway
                        self.update(content)
                    }
                } catch {
                    content.cutawayUnavailable = true
                }
            }
        }

        func update(_ value: GeographicMapboxCanvas) {
            guard let container else { return }
            content = value
            if sourceScene != value.scene || sourceReference != value.reference
                || sourceFootprints != value.map.footprints || sourceFloorY != value.map.floorY {
                geometry = GeographicMapboxGeometry(scene: value.scene, map: value.map, reference: value.reference)
                sourceScene = value.scene
                sourceReference = value.reference
                sourceFootprints = value.map.footprints
                sourceFloorY = value.map.floorY
                fitPending = true
                if value.accessToken == nil {
                    if localExteriorOutline == nil, let geometry {
                        localExteriorOutline = GeographicMapboxCanvas.localExteriorOutline(geometry)
                    }
                } else {
                    queryGeneration += 1
                    exteriorQuery?.cancel()
                    exteriorQuery = nil
                    exteriorCutaway = nil
                    requestedExterior = false
                }
            }
            guard let geometry else { return }
            container.bottomInset = value.bottomInset
            var ornaments = container.mapView.ornaments.options
            ornaments.compass.visibility = .hidden
            ornaments.scaleBar.visibility = .hidden
            // Keep the provider's logo and attribution accessible above our sheet.
            ornaments.logo.margins = CGPoint(x: 8, y: value.bottomInset + 8)
            ornaments.attributionButton.margins = CGPoint(x: 8, y: value.bottomInset + 8)
            container.mapView.ornaments.options = ornaments

            let route = geometry.path(value.routePoints)
            let user = geometry.point(value.userPosition)
            let target = geometry.point(value.destination)
            let wallHeight: Double = value.topDown ? 0.12 : 0.70
            let floorAltitude = max(0, Double(value.map.floorY - (value.groundFloorY ?? value.map.floorY)))
            let clip = exteriorCutaway?.clip ?? FeatureCollection(features: [])
            let remainder = value.accessToken == nil
                ? geometry.exampleExterior(outline: localExteriorOutline ?? [])
                : exteriorCutaway?.remainder ?? FeatureCollection(features: [])

            container.mapView.mapboxMap.setMapStyleContent {
                GeoJSONSource(id: "inview-footprint").data(.featureCollection(geometry.floorFeatures))
                GeoJSONSource(id: "inview-exterior-clip").data(.featureCollection(clip))
                // Native clip is feature replacement, not a surgical roof mask.
                // The source stays empty until the original feature's unmapped
                // remainder has been reconstructed successfully below.
                ClipLayer(id: "inview-building-cutaway", source: "inview-exterior-clip")
                    .clipLayerScope(["basemap"])
                    .clipLayerTypes([.model, .symbol])
                    .minZoom(17)
                FillExtrusionLayer(id: "inview-floor", source: "inview-footprint")
                    .fillExtrusionColor(UIColor(red: 0.95, green: 0.96, blue: 0.93, alpha: 1))
                    .fillExtrusionBase(0)
                    .fillExtrusionHeight(floorAltitude + 0.04)
                    .fillExtrusionVerticalGradient(false)
                    .minZoom(17)
                GeoJSONSource(id: "inview-walls").data(.featureCollection(geometry.wallFeatures))
                FillExtrusionLayer(id: "inview-wall-shapes", source: "inview-walls")
                    .fillExtrusionColor(UIColor(red: 0.88, green: 0.90, blue: 0.87, alpha: 1))
                    .filter(Exp(.lt) { Exp(.get) { "base" }; wallHeight })
                    .fillExtrusionBase(Exp(.sum) { Exp(.get) { "base" }; floorAltitude })
                    .fillExtrusionHeight(Exp(.sum) {
                        Exp(.min) { Exp(.get) { "height" }; wallHeight }; floorAltitude
                    })
                    .fillExtrusionVerticalGradient(false)
                    .fillExtrusionAmbientOcclusionIntensity(0.18)
                    .minZoom(17)
                GeoJSONSource(id: "inview-furniture").data(.featureCollection(geometry.objectFeatures))
                FillExtrusionLayer(id: "inview-furniture-shapes", source: "inview-furniture")
                    .fillExtrusionColor(UIColor(red: 0.75, green: 0.79, blue: 0.77, alpha: 1))
                    .fillExtrusionBase(Exp(.sum) { Exp(.get) { "base" }; floorAltitude })
                    .fillExtrusionHeight(Exp(.sum) { Exp(.get) { "height" }; floorAltitude })
                    .fillExtrusionVerticalGradient(false)
                    .fillExtrusionAmbientOcclusionIntensity(0.12)
                    .minZoom(17)
                // The unmapped remainder is a continuous cutaway at the selected level.
                // A translucent extrusion exposes every hidden sidewall and roof behind it.
                GeoJSONSource(id: "inview-exterior-remainder").data(.featureCollection(remainder))
                FillExtrusionLayer(id: "inview-exterior-remainder-shapes", source: "inview-exterior-remainder")
                    .fillExtrusionColor(UIColor(red: 0.84, green: 0.84, blue: 0.81, alpha: 1))
                    .fillExtrusionOpacity(1)
                    .filter(Exp(.lt) { Exp(.get) { "base" }; floorAltitude + wallHeight })
                    .fillExtrusionBase(Exp(.get) { "base" })
                    .fillExtrusionHeight(Exp(.min) { Exp(.get) { "height" }; floorAltitude + wallHeight })
                    .fillExtrusionVerticalGradient(false)
                    .fillExtrusionCastShadows(false)
                    .minZoom(17)
                GeoJSONSource(id: "inview-route").data(.featureCollection(route))
                LineLayer(id: "inview-route-casing", source: "inview-route")
                    .lineColor(UIColor.white).lineWidth(7).lineCap(.round).lineJoin(.round)
                LineLayer(id: "inview-route-line", source: "inview-route")
                    .lineColor(Theme.routeUIColor).lineWidth(4).lineCap(.round).lineJoin(.round)
                // The destination uses the same badge as the indoor maps and lists.
                StyleImage(id: "inview-destination-badge", image: value.destinationBadge)
                GeoJSONSource(id: "inview-destination").data(.featureCollection(target))
                SymbolLayer(id: "inview-destination-badge", source: "inview-destination")
                    .iconImage("inview-destination-badge")
                    .iconAllowOverlap(true)
                    .iconIgnorePlacement(true)
                GeoJSONSource(id: "inview-position").data(.featureCollection(user))
                CircleLayer(id: "inview-position-dot", source: "inview-position")
                    .circleColor(Theme.routeUIColor).circleRadius(7)
                    .circleStrokeColor(UIColor.white).circleStrokeWidth(3)
            }
            if lastResetID != value.resetID { fitPending = true }
            if let lastTopDown, lastTopDown != value.topDown, !fitPending {
                container.mapView.camera.ease(to: CameraOptions(pitch: value.topDown ? 0 : 50), duration: 0.35)
            }
            lastTopDown = value.topDown
            lastResetID = value.resetID
            fitIfNeeded()
        }

        func fitIfNeeded() {
            guard fitPending, let container, let content, let geometry,
                  container.bounds.width > 100,
                  container.bounds.height > content.bottomInset + 160 else { return }
            let padding = UIEdgeInsets(top: 110, left: 32, bottom: content.bottomInset + 48, right: 32)
            let camera = CameraOptions(padding: padding, bearing: content.reference.headingDegrees + 35,
                                       pitch: content.topDown ? 0 : 50)
            let coordinates = content.accessToken == nil
                ? (localExteriorOutline ?? []).compactMap { geometry.coordinate($0) }
                : geometry.fitCoordinates
            guard let fitted = try? container.mapView.mapboxMap.camera(
                for: coordinates, camera: camera,
                coordinatesPadding: .zero, maxZoom: content.accessToken == nil ? 21.5 : 19.5,
                offset: nil) else { return }
            container.mapView.mapboxMap.setCamera(to: fitted)
            fitPending = false
        }
    }
}

private final class GeographicMapboxContainer: UIView {
    let mapView: MapboxMaps.MapView
    var bottomInset: CGFloat = 0
    var onLayout: (() -> Void)?

    init(options: MapInitOptions) {
        mapView = MapboxMaps.MapView(frame: .zero, mapInitOptions: options)
        super.init(frame: .zero)
        addSubview(mapView)
        mapView.accessibilityLabel = "Indoor and outdoor map"
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        onLayout?()
    }
}

/// Geometry stays in the scan's unchanged meter-based frame until conversion at
/// this rendering boundary. A scan's tracked indoor position is not GPS-derived.
private struct GeographicMapboxGeometry {
    let reference: BuildingMapReference
    let floorPolygons: [[SIMD2<Float>]]
    let floorFeatures: FeatureCollection
    let wallFeatures: FeatureCollection
    let objectFeatures: FeatureCollection
    let fitCoordinates: [CLLocationCoordinate2D]

    init(scene: ProcessedScene?, map: VenueMap, reference: BuildingMapReference) {
        self.reference = reference
        var floors: [[SIMD2<Float>]] = []
        var walls: [(points: [SIMD2<Float>], base: Float, height: Float)] = []
        var sceneWalls: [(footprint: Footprint, base: Float, height: Float)] = []
        var objects: [(points: [SIMD2<Float>], base: Float, height: Float)] = []
        if let scene {
            for surface in scene.surfaces {
                guard let pose = Self.matrix(surface.mapFromSurface),
                      var size = Self.vector(surface.renderDimensionsM) else { continue }
                if surface.kind == "floor" {
                    if let polygon = surface.polygonCorners, polygon.count >= 3 {
                        let projected = polygon.compactMap { point -> SIMD2<Float>? in
                            guard let vertex = Self.vector(point) else { return nil }
                            let world = pose * SIMD4(vertex, 1)
                            return SIMD2(world.x, world.z)
                        }
                        if projected.count == polygon.count { floors.append(projected); continue }
                    }
                    if let measured = Self.vector(surface.measuredDimensionsM) { size = measured }
                    let normal = (0..<3).min { size[$0] < size[$1] } ?? 1
                    size[normal] = 0
                    floors.append(Self.projectedBox(pose: pose, size: size, center: .zero))
                } else if surface.kind == "wall" {
                    // Use the scan's oriented wall footprint. Passage rectangles
                    // are removed below, so navigation never draws a sealed door.
                    var wallPose = pose
                    if size.z > size.x {
                        wallPose *= simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 1, 0]))
                        size = SIMD3(size.z, size.y, size.x)
                    }
                    let base = max(0.04, wallPose.translation.y - size.y / 2 - map.floorY)
                    let height = max(base + 0.01, wallPose.translation.y + size.y / 2 - map.floorY)
                    sceneWalls.append((Footprint(kind: .wall, transform: wallPose,
                                                 width: size.x, depth: max(0.10, size.z)), base, height))
                }
            }
            for object in scene.objects {
                guard let pose = Self.matrix(object.mapFromObject) else { continue }
                for part in object.parts {
                    guard let size = Self.vector(part.dimensionsM), let center = Self.vector(part.center) else { continue }
                    let corners = Self.boxPoints(pose: pose, size: size, center: center)
                    let base = max(0, (corners.map(\.y).min() ?? map.floorY) - map.floorY)
                    let height = max(base + 0.01, (corners.map(\.y).max() ?? map.floorY) - map.floorY)
                    objects.append((Self.hull(corners.map { SIMD2($0.x, $0.z) }), base, height))
                }
                if object.parts.isEmpty {
                    let corners = object.obstacleCorners.compactMap(Self.vector)
                    if !corners.isEmpty {
                        let base = max(0, (corners.map(\.y).min() ?? map.floorY) - map.floorY)
                        let height = max(base + 0.01, (corners.map(\.y).max() ?? map.floorY) - map.floorY)
                        objects.append((Self.hull(corners.map { SIMD2($0.x, $0.z) }), base, height))
                    }
                }
            }
        }
        let passages = map.footprints.filter { $0.kind == .door || $0.kind == .opening }
        // Never infer a building-wide floor from wall bounds: a partial scan
        // must leave unmapped wings and gaps intact. An older scan without floor
        // surfaces leaves the exterior unclipped until its outline is available.
        let wallFootprints = sceneWalls.isEmpty
            ? map.footprints.filter { $0.kind == .wall }.map { (footprint: $0, base: Float(0.04), height: Float(0.70)) }
            : sceneWalls
        if !wallFootprints.isEmpty {
            walls = wallFootprints.flatMap { panel -> [(points: [SIMD2<Float>], base: Float, height: Float)] in
                let wall = panel.footprint
                let intersecting = passages.filter { passage in
                    abs(wall.local(passage.center).y) <= (wall.size.y + passage.size.y) / 2 + 0.15
                        && abs(wall.local(passage.center).x) <= (wall.size.x + passage.size.x) / 2
                }
                var intervals: [(Float, Float)] = [(-wall.size.x / 2, wall.size.x / 2)]
                for passage in intersecting {
                    let along = passage.corners.map { wall.local($0).x }
                    guard let start = along.min(), let end = along.max() else { continue }
                    intervals = intervals.flatMap { a, b in
                        if end <= a || start >= b { return [(a, b)] }
                        return [(a, min(b, start)), (max(a, end), b)].filter { $0.1 - $0.0 > 0.01 }
                    }
                }
                return intervals.map { a, b in
                    let direction = SIMD2(cos(wall.yaw), sin(wall.yaw))
                    let footprint = Footprint(kind: .wall, center: wall.center + direction * ((a + b) / 2),
                                              size: SIMD2(b - a, max(0.10, wall.size.y)), yaw: wall.yaw)
                    return (footprint.corners, panel.base, panel.height)
                }
            }
        }
        if objects.isEmpty {
            objects = map.footprints.filter { $0.kind == .obstacle || $0.kind == .stairs }
                .map { ($0.corners, 0, $0.kind == .stairs ? 0.15 : 0.55) }
        }
        // Native RoomPlan polygons survive in VenueMap even when an older portable scene
        // only has a floor's rectangular dimensions. Prefer the measured room boundary.
        let measuredFloors = map.footprints.filter { $0.kind == .floor }.map(\.corners)
        if floors.isEmpty { floors = measuredFloors }
        func polygon(_ points: [SIMD2<Float>], properties: JSONObject? = nil) -> Feature? {
            // Local X/Z is right handed with +Z south; geographic longitude /
            // latitude reverses that winding. GeoJSON outer rings are CCW.
            let coordinates = points.reversed().compactMap { Self.coordinate($0, reference: reference) }
            guard coordinates.count == points.count, coordinates.count >= 3, let first = coordinates.first else { return nil }
            var feature = Feature(geometry: Polygon([coordinates + [first]]))
            feature.properties = properties
            return feature
        }
        // Render each connected floor once. Overlapping room rectangles at the same height
        // produce coplanar faces and striped surfaces if they are extruded separately.
        let floorRegions = (try? BuildingFootprintCutaway.unionRegions(floors))
            ?? floors.map { BuildingFootprintCutaway.Region(exterior: $0) }
        floorFeatures = FeatureCollection(features: floorRegions.compactMap {
            Self.feature(exterior: $0.exterior, holes: $0.holes, reference: reference)
        })
        floorPolygons = floors
        wallFeatures = FeatureCollection(features: walls.compactMap {
            polygon($0.points, properties: ["base": .number(Double($0.base)), "height": .number(Double($0.height))])
        })
        objectFeatures = FeatureCollection(features: objects.compactMap {
            polygon($0.points, properties: ["base": .number(Double($0.base)), "height": .number(Double($0.height))])
        })
        let fitPoints = floors.isEmpty ? map.footprints.flatMap(\.corners) : floors.flatMap { $0 }
        fitCoordinates = fitPoints.compactMap { Self.coordinate($0, reference: reference) }
    }

    func path(_ points: [SIMD2<Float>]) -> FeatureCollection {
        let coordinates = points.compactMap { Self.coordinate($0, reference: reference) }
        guard coordinates.count == points.count, coordinates.count >= 2 else { return .init(features: []) }
        return .init(features: [Feature(geometry: LineString(coordinates))])
    }

    func point(_ point: SIMD2<Float>?) -> FeatureCollection {
        guard let point, let coordinate = Self.coordinate(point, reference: reference) else { return .init(features: []) }
        return .init(features: [Feature(geometry: Point(coordinate))])
    }

    /// The local example follows the same layer order as the live exterior.
    func exampleExterior(outline: [SIMD2<Float>]) -> FeatureCollection {
        guard let regions = try? BuildingFootprintCutaway.subtractRegions(mapped: floorPolygons, from: outline) else {
            return .init(features: [])
        }
        return FeatureCollection(features: regions.compactMap {
            Self.feature(exterior: $0.exterior, holes: $0.holes, reference: reference,
                         properties: ["base": .number(0), "height": .number(6)])
        })
    }

    struct ExteriorCutaway {
        let clip: FeatureCollection
        let remainder: FeatureCollection
    }

    private enum CutawayError: Error { case invalidExterior }

    /// Standard's featureset exposes the original building part geometry and
    /// height. Reconstruct its unmapped portion before enabling native feature
    /// replacement. Any invalid required geometry leaves the original intact.
    func cutaway(buildings: [StandardBuildingsFeature]) throws -> ExteriorCutaway {
        var features: [Feature] = []
        var seen = Set<Data>()
        var renderedRegions = Set<Data>()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var changed = false
        for building in buildings {
            if building.group == "building-2d" { continue }
            let polygons: [[[CLLocationCoordinate2D]]]
            switch building.geometry {
            case .polygon(let polygon): polygons = [polygon.coordinates]
            case .multiPolygon(let multiPolygon): polygons = multiPolygon.coordinates
            default: throw CutawayError.invalidExterior
            }
            var encoded = try JSONEncoder().encode(building.geometry)
            encoded.append(contentsOf: "|\(building.height ?? -1)|\(building.minHeight ?? 0)".utf8)
            guard seen.insert(encoded).inserted else { continue }
            var buildingRegions: [BuildingFootprintCutaway.Region] = []
            var buildingChanged = false
            for rings in polygons {
                let local = try rings.map { ring in
                    try ring.map { try reference.mapPoint(for: .init(latitude: $0.latitude, longitude: $0.longitude)) }
                }
                guard let exterior = local.first else { throw CutawayError.invalidExterior }
                let holes = Array(local.dropFirst())
                let regions = try BuildingFootprintCutaway.subtractRegions(mapped: floorPolygons, from: exterior, holes: holes)
                let originalArea = Self.area(exterior) - holes.reduce(0) { $0 + Self.area($1) }
                let remainderArea = regions.reduce(0) {
                    $0 + Self.area($1.exterior) - $1.holes.reduce(0) { $0 + Self.area($1) }
                }
                guard originalArea.isFinite, originalArea > 0, remainderArea.isFinite else { throw CutawayError.invalidExterior }
                if originalArea - remainderArea > 0.001 { buildingChanged = true }
                buildingRegions.append(contentsOf: regions)
            }
            // Native clipping replaces an entire feature, including disconnected components.
            // Preserve every untouched wing of a MultiPolygon belonging to a replaced building.
            if buildingChanged {
                // Only replaced buildings need height metadata. An unrelated nearby building
                // with incomplete attributes must not prevent the interior from opening.
                guard let height = building.height, height.isFinite, height > 0 else { throw CutawayError.invalidExterior }
                let base = building.minHeight ?? 0
                guard base.isFinite, base >= 0, base <= height else { throw CutawayError.invalidExterior }
                for region in buildingRegions {
                    guard let feature = Self.feature(exterior: region.exterior, holes: region.holes, reference: reference,
                                                     properties: ["base": .number(base), "height": .number(height)]) else {
                        throw CutawayError.invalidExterior
                    }
                    // Equivalent rings can arrive with different starting vertices or winding
                    // from neighboring map tiles. Region boundaries are canonicalized first.
                    if renderedRegions.insert(try encoder.encode(feature)).inserted { features.append(feature) }
                }
                changed = true
            }
        }
        return ExteriorCutaway(clip: changed ? floorFeatures : .init(features: []),
                               remainder: .init(features: features))
    }

    func coordinate(_ point: SIMD2<Float>) -> CLLocationCoordinate2D? {
        Self.coordinate(point, reference: reference)
    }

    private static func feature(exterior: [SIMD2<Float>], holes: [[SIMD2<Float>]],
                                reference: BuildingMapReference, properties: JSONObject? = nil) -> Feature? {
        var rings: [[CLLocationCoordinate2D]] = []
        for points in [exterior] + holes {
            let coordinates = points.reversed().compactMap { coordinate($0, reference: reference) }
            guard coordinates.count == points.count, coordinates.count >= 3, let first = coordinates.first else { return nil }
            rings.append(coordinates + [first])
        }
        var feature = Feature(geometry: Polygon(rings))
        feature.properties = properties
        return feature
    }

    private static func area(_ polygon: [SIMD2<Float>]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        return abs(polygon.indices.reduce(0.0) { total, index in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            return total + Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }) / 2
    }

    private static func coordinate(_ point: SIMD2<Float>, reference: BuildingMapReference) -> CLLocationCoordinate2D? {
        guard point.x.isFinite, point.y.isFinite, let coordinate = try? reference.coordinate(for: point) else { return nil }
        return CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])))
    }

    private static func vector(_ values: [Float]) -> SIMD3<Float>? {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private static func boxPoints(pose: simd_float4x4, size: SIMD3<Float>, center: SIMD3<Float>) -> [SIMD3<Float>] {
        [-1, 1].flatMap { x in [-1, 1].flatMap { y in [-1, 1].map { z in
            let local = center + size * SIMD3(Float(x), Float(y), Float(z)) / 2
            let point = pose * SIMD4(local, 1)
            return SIMD3(point.x, point.y, point.z)
        } } }
    }

    private static func projectedBox(pose: simd_float4x4, size: SIMD3<Float>, center: SIMD3<Float>) -> [SIMD2<Float>] {
        hull(boxPoints(pose: pose, size: size, center: center).map { SIMD2($0.x, $0.z) })
    }

    private static func hull(_ input: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let points = input.filter { $0.x.isFinite && $0.y.isFinite }.sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }.reduce(into: [SIMD2<Float>]()) { result, point in
            if result.last != point { result.append(point) }
        }
        guard points.count >= 3 else { return points }
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func chain(_ values: [SIMD2<Float>]) -> [SIMD2<Float>] {
            var result: [SIMD2<Float>] = []
            for point in values {
                while result.count >= 2 && cross(result[result.count - 2], result[result.count - 1], point) <= 0 { result.removeLast() }
                result.append(point)
            }
            result.removeLast()
            return result
        }
        return chain(points) + chain(Array(points.reversed()))
    }
}
