import AccessCore
import SceneKit
import simd
import SwiftUI
import UIKit

/// Native map canvas. Models retain the measured map frame supplied by the backend.
struct RoomMapCanvas: UIViewRepresentable {
    let scene: ProcessedScene
    @Binding var selectedObjectID: String?
    var showsLabels = false
    var floorFootprints: [Footprint] = []
    var topDown = false
    var resetID = 0
    var showsDetails = false
    var showsFullWalls = false
    var viewportBottomInset: CGFloat = 0
    /// Floor coordinates are (map x, map z), in the capture's original meter frame.
    var routePoints: [SIMD2<Float>] = []
    var userPosition: SIMD2<Float>? = nil
    /// Radians: zero faces -Z; positive pi/2 faces +X.
    var userHeading: Float? = nil
    var floorY: Float = 0
    var destination: SIMD2<Float>? = nil
    var destinationTitle: String? = nil
    var isNavigating = false

    func makeUIView(context: Context) -> RoomMapRenderView {
        let view = RoomMapRenderView()
        configure(view)
        return view
    }

    func updateUIView(_ view: RoomMapRenderView, context: Context) { configure(view) }

    private func configure(_ view: RoomMapRenderView) {
        let selection = $selectedObjectID
        view.onSelection = { selection.wrappedValue = $0 }
        view.update(scene, selectedObjectID: selectedObjectID, showsLabels: showsLabels,
                    floorFootprints: floorFootprints,
                    topDown: topDown, resetID: resetID, showsDetails: showsDetails,
                    showsFullWalls: showsFullWalls, viewportBottomInset: viewportBottomInset,
                    routePoints: routePoints, userPosition: userPosition, userHeading: userHeading,
                    floorY: floorY, destination: destination, destinationTitle: destinationTitle,
                    isNavigating: isNavigating)
    }
}

@MainActor
final class RoomMapRenderView: UIView, UIGestureRecognizerDelegate {
    var onSelection: ((String?) -> Void)?
    private let canvas = SCNView()
    private let world = SCNScene()
    private let room = SCNNode()
    private let shell = SCNNode()
    private let details = SCNNode()
    private let highlight = SCNNode()
    private let navigation = SCNNode()
    private let route = SCNNode()
    private let heading = SCNNode()
    private let goal = SCNNode()
    private let locationDot = UIView()
    private let camera = SCNNode()
    private let sun = SCNNode()
    private var source: ProcessedScene?
    private var savedFloors: [Footprint] = []
    private var measuredFloors: [Footprint] = []
    private var floorRegions: [(elevation: Float, region: BuildingFootprintCutaway.Region)] = []
    private var labels: [(id: String, position: SIMD3<Float>, view: RoomObjectLabel)] = []
    private var selection: String?
    private var labelsVisible = true
    private var fullWalls = false
    private var flat = false
    private var lastResetID = 0
    private var detailsBuilt = false
    private var shellConfiguration = ""
    private var bottomInset: CGFloat = 0
    private var lower = SIMD3<Float>(repeating: -0.5)
    private var upper = SIMD3<Float>(repeating: 0.5)
    private var yaw: Float = .pi * 3 / 4
    private var pitch: Float = 0.68
    private var zoom: Float = 1
    private var displayLink: CADisplayLink?
    private var needsViewportRefresh = true
    private var isNavigating = false
    private var routePoints: [SIMD2<Float>] = []
    private var userPosition: SIMD2<Float>?
    private var userHeading: Float?
    private var floorY: Float = 0
    private var destination: SIMD2<Float>?
    private var destinationTitle: String?
    private var destinationLabel: RoomObjectLabel?
    /// Unit-size templates share geometry and materials; each instance owns its pose and scale.
    private var catalogGeometries: [String: [SCNGeometry]] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(roomHex: "#eaece7")
        canvas.backgroundColor = backgroundColor
        world.background.contents = backgroundColor
        canvas.scene = world
        canvas.antialiasingMode = .multisampling4X
        canvas.preferredFramesPerSecond = 60
        canvas.autoenablesDefaultLighting = false
        canvas.allowsCameraControl = false
        canvas.isPlaying = true
        addSubview(canvas)
        world.rootNode.addChildNode(room)
        room.addChildNode(shell)
        room.addChildNode(details)
        room.addChildNode(highlight)
        room.addChildNode(navigation)
        navigation.addChildNode(route)
        navigation.addChildNode(heading)
        navigation.addChildNode(goal)
        locationDot.backgroundColor = .systemBlue
        locationDot.layer.cornerRadius = 8
        locationDot.layer.borderWidth = 2.5
        locationDot.layer.borderColor = UIColor.white.cgColor
        locationDot.layer.shadowColor = UIColor.black.cgColor
        locationDot.layer.shadowOpacity = 0.18
        locationDot.layer.shadowRadius = 3
        locationDot.layer.shadowOffset = CGSize(width: 0, height: 1)
        locationDot.isUserInteractionEnabled = false
        locationDot.isAccessibilityElement = true
        locationDot.accessibilityLabel = "Your location"
        locationDot.isHidden = true
        addSubview(locationDot)
        let projection = SCNCamera()
        projection.usesOrthographicProjection = true
        projection.projectionDirection = .vertical
        projection.zNear = 0.01
        projection.zFar = 1_000
        projection.wantsHDR = true
        projection.wantsExposureAdaptation = false
        projection.exposureOffset = 0
        projection.screenSpaceAmbientOcclusionIntensity = 0.65
        projection.screenSpaceAmbientOcclusionRadius = 0.22
        projection.screenSpaceAmbientOcclusionBias = 0.015
        projection.screenSpaceAmbientOcclusionDepthThreshold = 0.5
        projection.bloomIntensity = 0
        camera.camera = projection
        world.rootNode.addChildNode(camera)
        canvas.pointOfView = camera
        installLighting()
        let drag = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        canvas.addGestureRecognizer(drag)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(magnify(_:)))
        pinch.delegate = self
        canvas.addGestureRecognizer(pinch)
        canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectObject(_:))))
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = "Room model"
        canvas.accessibilityHint = "Drag to rotate, pinch to zoom, or tap an item"
        canvas.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Rotate left", target: self, selector: #selector(rotateLeft)),
            UIAccessibilityCustomAction(name: "Rotate right", target: self, selector: #selector(rotateRight)),
            UIAccessibilityCustomAction(name: "Zoom in", target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: "Zoom out", target: self, selector: #selector(zoomOut)),
            UIAccessibilityCustomAction(name: "Reset view", target: self, selector: #selector(resetView))
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        updateCamera()
        needsViewportRefresh = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil {
            needsViewportRefresh = true
            let link = CADisplayLink(target: self, selector: #selector(displayFrame))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func displayFrame() {
        if needsViewportRefresh, canvas.bounds.width > 0, canvas.bounds.height > 0 {
            // SceneKit establishes its viewport after the initial UIKit layout.
            needsViewportRefresh = false
            canvas.layoutIfNeeded()
            updateCamera()
        } else {
            positionLabels()
        }
    }

    func update(_ source: ProcessedScene, selectedObjectID: String?, showsLabels: Bool,
                floorFootprints: [Footprint],
                topDown: Bool, resetID: Int, showsDetails: Bool, showsFullWalls: Bool,
                viewportBottomInset: CGFloat, routePoints: [SIMD2<Float>], userPosition: SIMD2<Float>?,
                userHeading: Float?, floorY: Float, destination: SIMD2<Float>?,
                destinationTitle: String?, isNavigating: Bool) {
        let changed = self.source != source
        if changed || savedFloors != floorFootprints {
            savedFloors = floorFootprints
            measuredFloors = floorFootprints.isEmpty ? source.surfaces.compactMap(measuredFloor) : floorFootprints
            floorRegions = Self.mergeFloors(measuredFloors)
            shellConfiguration = ""
        }
        if changed {
            needsViewportRefresh = true
            self.source = source
            for child in room.childNodes where child !== shell && child !== details && child !== highlight && child !== navigation { child.removeFromParentNode() }
            details.childNodes.forEach { $0.removeFromParentNode() }
            detailsBuilt = false
            shellConfiguration = ""
            buildObjects(source)
            buildLabels(source)
            resetOrbit()
        }
        if flat != topDown || fullWalls != showsFullWalls {
            flat = topDown
            fullWalls = showsFullWalls
            shellConfiguration = ""
        }
        bottomInset = max(0, viewportBottomInset)
        self.isNavigating = isNavigating
        labelsVisible = showsLabels && !isNavigating
        highlight.isHidden = isNavigating
        canvas.accessibilityLabel = isNavigating ? "Navigation map" : "Room model"
        canvas.accessibilityHint = isNavigating ? "Drag to rotate or pinch to zoom" : "Drag to rotate, pinch to zoom, or tap an item"
        updateNavigation(routePoints: routePoints, userPosition: userPosition, userHeading: userHeading,
                         floorY: floorY, destination: destination, destinationTitle: destinationTitle)
        // Reconstructed stream geometry is the model, including when compact floor measurements exist.
        let streamModel = source.meshes.contains { $0.sourceID == "stream-depth-fusion" }
        details.isHidden = !(streamModel || showsDetails || (source.objects.isEmpty && source.surfaces.isEmpty))
        if !details.isHidden && !detailsBuilt { buildDetails(source); detailsBuilt = true }
        fitBounds(source)
        updateShellIfNeeded()
        if changed || selection != selectedObjectID { selection = selectedObjectID; buildSelection() }
        if resetID != lastResetID { lastResetID = resetID; resetOrbit(); updateShellIfNeeded() }
        updateCamera()
    }

    private func installLighting() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(roomHex: "#f5f7fa")
        ambient.light?.intensity = 180
        world.rootNode.addChildNode(ambient)
        let light = SCNLight()
        light.type = .directional
        light.color = UIColor.white
        light.intensity = 650
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowColor = UIColor(roomHex: "#35434b").withAlphaComponent(0.30)
        light.shadowMapSize = CGSize(width: 2_048, height: 2_048)
        light.shadowRadius = 4
        light.shadowSampleCount = 32
        light.shadowBias = 0.03
        light.orthographicScale = 12
        light.zNear = 0.1
        light.zFar = 80
        sun.light = light
        sun.simdPosition = [5, 10, -5]
        sun.look(at: SCNVector3Zero)
        world.rootNode.addChildNode(sun)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.color = UIColor(roomHex: "#edf3f8")
        fill.light?.intensity = 130
        fill.simdPosition = [-6, 5, 7]
        fill.look(at: SCNVector3Zero)
        world.rootNode.addChildNode(fill)
        world.lightingEnvironment.contents = lightingImage()
        world.lightingEnvironment.intensity = 0.22
    }

    private func lightingImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128)).image { context in
            UIColor(roomHex: "#e4e6e4").setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            let colors = [UIColor.white.cgColor, UIColor(roomHex: "#d4d9d7").cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
            }
        }
    }

    private func matte(_ color: String, opacity: CGFloat = 1) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(roomHex: color)
        material.roughness.contents = 0.90
        material.metalness.contents = 0
        material.transparency = opacity
        material.isDoubleSided = true
        return material
    }

    private func box(_ dimensions: SIMD3<Float>, color: String, radius: CGFloat = 0.015) -> SCNNode {
        let bevel = min(radius, CGFloat(dimensions.min() / 3))
        let geometry = SCNBox(width: CGFloat(dimensions.x), height: CGFloat(dimensions.y), length: CGFloat(dimensions.z), chamferRadius: bevel)
        geometry.chamferSegmentCount = 3
        geometry.materials = [matte(color)]
        return SCNNode(geometry: geometry)
    }

    private func buildObjects(_ source: ProcessedScene) {
        for object in source.objects {
            guard let pose = matrix(object.mapFromObject) else { continue }
            let parent = SCNNode()
            parent.name = "object:\(object.sourceID)"
            parent.simdTransform = pose
            if !object.modelMeshes.isEmpty {
                for mesh in object.modelMeshes {
                    if let geometry = meshGeometry(vertices: mesh.vertices, normals: mesh.normals, triangles: mesh.triangles, color: "#c4cac8") {
                        parent.addChildNode(SCNNode(geometry: geometry))
                    }
                }
            } else if let size = vector(object.measuredDimensionsM), size.min() > 0,
                      let geometries = catalogGeometry(for: object.modelKey) {
                parent.simdScale = size
                for geometry in geometries { parent.addChildNode(SCNNode(geometry: geometry)) }
            } else {
                for part in object.parts {
                    guard let size = vector(part.dimensionsM), let center = vector(part.center), size.min() > 0 else { continue }
                    let node = box(size, color: "#c4cac8")
                    node.simdPosition = center
                    parent.addChildNode(node)
                }
            }
            room.addChildNode(parent)
        }
    }

    private func catalogGeometry(for key: String) -> [SCNGeometry]? {
        if let cached = catalogGeometries[key] { return cached.isEmpty ? nil : cached }
        guard let meshes = try? FurnitureModelCatalog.meshes(for: key, dimensions: [1, 1, 1]),
              !meshes.isEmpty else {
            catalogGeometries[key] = []
            return nil
        }
        let geometries = meshes.compactMap {
            meshGeometry(vertices: $0.vertices, normals: $0.normals, triangles: $0.triangles, color: "#c4cac8")
        }
        guard geometries.count == meshes.count else {
            catalogGeometries[key] = []
            return nil
        }
        catalogGeometries[key] = geometries
        return geometries
    }

    private func meshGeometry(vertices: [[Float]], normals: [[Float]], triangles: [[Int]], color: String) -> SCNGeometry? {
        let positions = vertices.compactMap(vector)
        guard positions.count == vertices.count, !positions.isEmpty else { return nil }
        var sources = [SCNGeometrySource(vertices: positions.map(scn))]
        let directions = normals.compactMap(vector)
        if directions.count == positions.count { sources.append(SCNGeometrySource(normals: directions.map(scn))) }
        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count * 3)
        for face in triangles where face.count == 3 && face.allSatisfy({ $0 >= 0 && $0 < positions.count }) {
            indices.append(contentsOf: face.map(UInt32.init))
        }
        guard !indices.isEmpty else { return nil }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])
        geometry.materials = [matte(color)]
        return geometry
    }

    private var towardsCamera: SIMD3<Float> {
        let elevation: Float = flat ? .pi / 2 - 0.001 : pitch
        return SIMD3(cos(elevation) * sin(yaw), sin(elevation), cos(elevation) * cos(yaw))
    }

    private func wallHeight(_ surface: SceneSurface) -> Float {
        let size = vector(surface.renderDimensionsM) ?? [1, 1, 0.1]
        if fullWalls { return size.y }
        if flat { return min(0.12, size.y) }
        let position = matrix(surface.mapFromSurface)?.columns.3 ?? SIMD4<Float>(0, 0, 0, 1)
        let center = (lower + upper) / 2
        let near = simd_dot(SIMD3(position.x - center.x, 0, position.z - center.z), SIMD3(towardsCamera.x, 0, towardsCamera.z)) > 0.12
        return min(near ? 0.14 : 1.05, size.y)
    }

    private func updateShellIfNeeded() {
        guard let source else { return }
        let key = source.surfaces.filter { $0.kind == "wall" }.map { "\($0.sourceID):\(wallHeight($0))" }.joined(separator: "|")
        let configuration = "\(fullWalls)-\(flat)-\(key)"
        guard configuration != shellConfiguration else { return }
        shellConfiguration = configuration
        shell.childNodes.forEach { $0.removeFromParentNode() }
        for floor in floorRegions { buildMeasuredFloor(floor.region, elevation: floor.elevation) }
        for surface in source.surfaces {
            if surface.kind == "floor", floorRegions.isEmpty { buildFloor(surface) }
            else if surface.kind == "wall" { buildWall(surface, source: source) }
        }
        if floorRegions.isEmpty, !source.surfaces.contains(where: { $0.kind == "floor" }) {
            let size = upper - lower
            let floor = box(SIMD3(max(1, size.x + 0.3), 0.16, max(1, size.z + 0.3)), color: "#eef0eb", radius: 0.025)
            floor.simdPosition = SIMD3((lower.x + upper.x) / 2, lower.y - 0.09, (lower.z + upper.z) / 2)
            floor.categoryBitMask = 4
            shell.addChildNode(floor)
        }
    }

    private func measuredFloor(_ surface: SceneSurface) -> Footprint? {
        guard surface.kind == "floor", let pose = matrix(surface.mapFromSurface),
              let dimensions = vector(surface.measuredDimensionsM) else { return nil }
        let polygon: [[Float]]
        if let measured = surface.polygonCorners, measured.count >= 3 {
            polygon = measured
        } else {
            let normal = (0..<3).min { dimensions[$0] < dimensions[$1] } ?? 1
            let axes = (0..<3).filter { $0 != normal }
            polygon = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map { signs in
                var point = SIMD3<Float>.zero
                point[axes[0]] = Float(signs[0]) * dimensions[axes[0]] / 2
                point[axes[1]] = Float(signs[1]) * dimensions[axes[1]] / 2
                return [point.x, point.y, point.z]
            }
        }
        let corners = polygon.compactMap { corner -> SIMD2<Float>? in
            guard let point = vector(corner) else { return nil }
            let world = pose * SIMD4(point, 1)
            return SIMD2(world.x, world.z)
        }
        guard corners.count == polygon.count else { return nil }
        return Footprint(floor: corners, bottom: pose.columns.3.y)
    }

    private static func mergeFloors(_ floors: [Footprint]) -> [(elevation: Float, region: BuildingFootprintCutaway.Region)] {
        var levels: [(elevation: Float, polygons: [[SIMD2<Float>]])] = []
        for floor in floors.sorted(by: { ($0.bottom ?? 0) < ($1.bottom ?? 0) }) {
            guard let elevation = floor.bottom, elevation.isFinite,
                  floor.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            if let index = levels.firstIndex(where: { abs($0.elevation - elevation) < 0.3 }) {
                levels[index].polygons.append(floor.corners)
            } else { levels.append((elevation, [floor.corners])) }
        }
        return levels.flatMap { level in
            // Preserve measured outlines on a complexity limit; never replace with a hull.
            let regions = (try? BuildingFootprintCutaway.unionRegions(level.polygons))
                ?? level.polygons.map { BuildingFootprintCutaway.Region(exterior: $0) }
            return regions.map { (level.elevation, $0) }
        }
    }

    private func buildMeasuredFloor(_ region: BuildingFootprintCutaway.Region, elevation: Float) {
        let path = UIBezierPath()
        path.usesEvenOddFillRule = true
        for ring in [region.exterior] + region.holes {
            guard let start = ring.first, ring.count >= 3 else { continue }
            path.move(to: CGPoint(x: CGFloat(start.x), y: CGFloat(start.y)))
            for point in ring.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
            path.close()
        }
        let geometry = SCNShape(path: path, extrusionDepth: 0.18)
        geometry.materials = [matte("#eef0eb")]
        let node = SCNNode(geometry: geometry)
        node.simdEulerAngles.x = .pi / 2
        node.simdPosition.y = elevation - 0.09
        node.categoryBitMask = 4
        shell.addChildNode(node)
    }

    private func buildFloor(_ surface: SceneSurface) {
        guard let pose = matrix(surface.mapFromSurface), let measured = vector(surface.measuredDimensionsM) else { return }
        let parent = SCNNode()
        parent.simdTransform = pose
        parent.categoryBitMask = 4
        let normalAxis = (0..<3).min { measured[$0] < measured[$1] } ?? 1
        let sign: Float = pose[normalAxis].y >= 0 ? 1 : -1
        var slabSize = measured
        slabSize[normalAxis] = 0.18
        let slab = box(slabSize, color: "#eef0eb", radius: 0.018)
        slab.simdPosition[normalAxis] = -sign * 0.09
        slab.categoryBitMask = 4
        parent.addChildNode(slab)
        shell.addChildNode(parent)
    }

    private struct WallRectangle {
        var minimum: SIMD2<Float>
        var maximum: SIMD2<Float>
    }

    private func verticalPresentation(_ surface: SceneSurface) -> (pose: simd_float4x4, dimensions: SIMD3<Float>)? {
        guard var pose = matrix(surface.mapFromSurface), var size = vector(surface.renderDimensionsM) else { return nil }
        // Older drafts represented a wall in local YZ. Rotate only its display frame into XY.
        if size.z > size.x {
            pose *= simd_float4x4(simd_quatf(angle: -.pi / 2, axis: [0, 1, 0]))
            size = SIMD3(size.z, size.y, size.x)
        }
        return (pose, size)
    }

    private func openingRectangles(in wall: SceneSurface, source: ProcessedScene) -> [(SceneSurface, WallRectangle)] {
        guard let wallDisplay = verticalPresentation(wall) else { return [] }
        return source.surfaces.compactMap { opening in
            guard ["door", "opening", "window"].contains(opening.kind), let display = verticalPresentation(opening) else { return nil }
            let relative = simd_inverse(wallDisplay.pose) * display.pose
            guard abs(relative.columns.2.z) > 0.98 else { return nil }
            let points = corners(display.dimensions, center: .zero).map { transformed($0, by: relative) }
            guard points.allSatisfy({ abs($0.z) < 0.20 }), let first = points.first else { return nil }
            var minimum = SIMD2(first.x, first.y)
            var maximum = minimum
            for point in points {
                minimum = simd_min(minimum, SIMD2(point.x, point.y))
                maximum = simd_max(maximum, SIMD2(point.x, point.y))
            }
            return (opening, WallRectangle(minimum: minimum, maximum: maximum))
        }
    }

    private func buildWall(_ surface: SceneSurface, source: ProcessedScene) {
        guard let display = verticalPresentation(surface) else { return }
        let pose = display.pose
        let measured = display.dimensions
        let thickness = max(0.10, measured.z)
        let height = wallHeight(surface)
        let minimumY = -measured.y / 2
        let visible = WallRectangle(minimum: SIMD2(-measured.x / 2, minimumY), maximum: SIMD2(measured.x / 2, minimumY + height))
        let openings = measured.z < 0.25 ? openingRectangles(in: surface, source: source) : []
        var panels = [visible]
        for (_, hole) in openings { panels = panels.flatMap { subtract(hole, from: $0) } }
        let parent = SCNNode()
        parent.simdTransform = pose
        parent.categoryBitMask = 4
        for panel in panels {
            let size = panel.maximum - panel.minimum
            let center = (panel.minimum + panel.maximum) / 2
            let node = box(SIMD3(size.x, size.y, thickness), color: "#f1f3ee", radius: 0.012)
            node.simdPosition = SIMD3(center.x, center.y, 0)
            node.categoryBitMask = 4
            parent.addChildNode(node)
        }
        for (opening, rectangle) in openings {
            guard opening.kind == "window", let clipped = intersection(rectangle, visible) else { continue }
            let height = clipped.maximum.y - clipped.minimum.y
            let midY = (clipped.minimum.y + clipped.maximum.y) / 2
            let pane = box(SIMD3(clipped.maximum.x - clipped.minimum.x, height, 0.008), color: "#c4ccca", radius: 0)
            pane.geometry?.materials = [matte("#c4ccca", opacity: 0.24)]
            pane.simdPosition = SIMD3((clipped.minimum.x + clipped.maximum.x) / 2, midY, 0)
            pane.castsShadow = false
            pane.categoryBitMask = 4
            parent.addChildNode(pane)
        }
        shell.addChildNode(parent)
    }

    private func intersection(_ a: WallRectangle, _ b: WallRectangle) -> WallRectangle? {
        let minimum = simd_max(a.minimum, b.minimum)
        let maximum = simd_min(a.maximum, b.maximum)
        return maximum.x > minimum.x && maximum.y > minimum.y ? WallRectangle(minimum: minimum, maximum: maximum) : nil
    }

    private func subtract(_ hole: WallRectangle, from panel: WallRectangle) -> [WallRectangle] {
        guard let cut = intersection(hole, panel) else { return [panel] }
        return [
            WallRectangle(minimum: panel.minimum, maximum: SIMD2(cut.minimum.x, panel.maximum.y)),
            WallRectangle(minimum: SIMD2(cut.maximum.x, panel.minimum.y), maximum: panel.maximum),
            WallRectangle(minimum: SIMD2(cut.minimum.x, panel.minimum.y), maximum: SIMD2(cut.maximum.x, cut.minimum.y)),
            WallRectangle(minimum: SIMD2(cut.minimum.x, cut.maximum.y), maximum: SIMD2(cut.maximum.x, panel.maximum.y))
        ].filter { $0.maximum.x - $0.minimum.x > 0.002 && $0.maximum.y - $0.minimum.y > 0.002 }
    }

    private func buildDetails(_ source: ProcessedScene) {
        if let mesh = source.meshes.first(where: { $0.sourceID == "stream-depth-fusion" }) {
            // Keep the indexed measured surface intact; skipping arbitrary triangles leaves holes.
            let positions = mesh.vertices.compactMap(vector)
            guard positions.count == mesh.vertices.count else { return }
            var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
            for triangle in mesh.triangles where triangle.count == 3 {
                guard triangle.allSatisfy({ positions.indices.contains($0) }) else { continue }
                let a = positions[triangle[0]], b = positions[triangle[1]], c = positions[triangle[2]]
                let normal = simd_cross(b - a, c - a)
                for index in triangle { normals[index] += normal }
            }
            let normalized = normals.map { array(simd_length_squared($0) > 1e-10 ? simd_normalize($0) : [0, 1, 0]) }
            if let geometry = meshGeometry(vertices: mesh.vertices, normals: normalized,
                                           triangles: mesh.triangles, color: "#b3bcba") {
                geometry.materials.first?.isDoubleSided = true
                let node = SCNNode(geometry: geometry)
                node.categoryBitMask = 8
                node.castsShadow = false
                details.addChildNode(node)
            }
            return
        }
        let total = source.meshes.reduce(0) { $0 + $1.triangles.count }
        let step = max(1, (total + 39_999) / 40_000)
        var index = 0
        var vertices: [[Float]] = []
        var normals: [[Float]] = []
        var triangles: [[Int]] = []
        for mesh in source.meshes {
            for face in mesh.triangles {
                defer { index += 1 }
                guard index.isMultiple(of: step), face.count == 3, face.allSatisfy({ $0 >= 0 && $0 < mesh.vertices.count }),
                      let a = vector(mesh.vertices[face[0]]), let b = vector(mesh.vertices[face[1]]), let c = vector(mesh.vertices[face[2]]) else { continue }
                let cross = simd_cross(b - a, c - a)
                guard simd_length_squared(cross) > 1e-10 else { continue }
                let normal = array(simd_normalize(cross))
                let start = vertices.count
                vertices.append(contentsOf: [array(a), array(b), array(c)])
                normals.append(contentsOf: [normal, normal, normal])
                triangles.append([start, start + 1, start + 2])
            }
        }
        if let geometry = meshGeometry(vertices: vertices, normals: normals, triangles: triangles, color: "#b3bcba") {
            geometry.materials.first?.transparency = 0.50
            let mesh = SCNNode(geometry: geometry)
            mesh.categoryBitMask = 8
            mesh.castsShadow = false
            details.addChildNode(mesh)
        }
        let pointStep = max(1, (source.pointCloud.count + 1_199) / 1_200)
        let marker = SCNSphere(radius: 0.012)
        marker.segmentCount = 5
        marker.materials = [matte("#909b97")]
        for index in stride(from: 0, to: source.pointCloud.count, by: pointStep) {
            guard let position = vector(source.pointCloud[index].position) else { continue }
            let point = SCNNode(geometry: marker)
            point.simdPosition = position
            point.categoryBitMask = 8
            point.castsShadow = false
            details.addChildNode(point)
        }
    }

    private func updateNavigation(routePoints: [SIMD2<Float>], userPosition: SIMD2<Float>?,
                                  userHeading: Float?, floorY: Float, destination: SIMD2<Float>?,
                                  destinationTitle: String?) {
        navigation.isHidden = !isNavigating || !floorY.isFinite
        guard floorY.isFinite else {
            route.childNodes.forEach { $0.removeFromParentNode() }
            heading.childNodes.forEach { $0.removeFromParentNode() }
            goal.isHidden = true
            self.routePoints = []
            self.userPosition = nil
            self.userHeading = nil
            self.destination = nil
            self.destinationTitle = nil
            destinationLabel?.isHidden = true
            locationDot.isHidden = true
            refreshAccessibility()
            return
        }
        func valid(_ point: SIMD2<Float>) -> Bool { point.x.isFinite && point.y.isFinite }
        let path = routePoints.count <= 4_096 && routePoints.allSatisfy(valid) ? routePoints : []
        let position = userPosition.flatMap { valid($0) ? $0 : nil }
        let bearing = userHeading.flatMap { $0.isFinite ? $0 : nil }
        let target = destination.flatMap { valid($0) ? $0 : nil }
        let title = destinationTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let floorChanged = self.floorY != floorY
        if self.routePoints != path || floorChanged {
            self.routePoints = path
            route.childNodes.forEach { $0.removeFromParentNode() }
            if path.count > 1 {
                route.addChildNode(routeRibbon(path, width: 0.20, altitude: floorY + 0.020, color: .white))
                route.addChildNode(routeRibbon(path, width: 0.13, altitude: floorY + 0.026, color: .systemBlue))
            }
        }
        if self.userHeading != bearing || heading.childNodes.isEmpty {
            heading.childNodes.forEach { $0.removeFromParentNode() }
            if bearing != nil {
                var positions = [SCNVector3Zero]
                var indices: [UInt32] = []
                for index in 0...16 {
                    let angle = -Float.pi / 6 + Float(index) * Float.pi / 48
                    positions.append(SCNVector3(sin(angle) * 0.68, 0, -cos(angle) * 0.68))
                    if index > 0 { indices.append(contentsOf: [0, UInt32(index + 1), UInt32(index)]) }
                }
                let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions)],
                                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
                geometry.materials = [mapInk(.systemBlue, opacity: 0.17)]
                let cone = SCNNode(geometry: geometry)
                cone.categoryBitMask = 32
                cone.castsShadow = false
                heading.addChildNode(cone)
            }
        }
        self.userPosition = position
        self.userHeading = bearing
        heading.isHidden = position == nil || bearing == nil
        if let position {
            heading.simdPosition = SIMD3(position.x, floorY + 0.030, position.y)
            heading.eulerAngles.y = -(bearing ?? 0)
        }
        if self.destination != target || self.destinationTitle != title || floorChanged {
            goal.childNodes.forEach { $0.removeFromParentNode() }
            destinationLabel?.removeFromSuperview()
            destinationLabel = nil
            if target != nil {
                let pin = UIBezierPath()
                pin.move(to: .zero)
                pin.addLine(to: CGPoint(x: -0.10, y: 0.17))
                pin.addCurve(to: CGPoint(x: 0, y: 0.44), controlPoint1: CGPoint(x: -0.23, y: 0.37), controlPoint2: CGPoint(x: -0.10, y: 0.44))
                pin.addCurve(to: CGPoint(x: 0.10, y: 0.17), controlPoint1: CGPoint(x: 0.10, y: 0.44), controlPoint2: CGPoint(x: 0.23, y: 0.37))
                pin.close()
                let shape = SCNShape(path: pin, extrusionDepth: 0.014)
                shape.chamferRadius = 0.004
                shape.materials = [mapInk(.systemBlue)]
                let pinNode = SCNNode(geometry: shape)
                pinNode.categoryBitMask = 32
                pinNode.castsShadow = false
                goal.addChildNode(pinNode)
                let dot = SCNCylinder(radius: 0.065, height: 0.009)
                dot.radialSegmentCount = 24
                dot.materials = [mapInk(.white)]
                let center = SCNNode(geometry: dot)
                center.eulerAngles.x = .pi / 2
                center.simdPosition = [0, 0.30, 0.024]
                center.categoryBitMask = 32
                center.castsShadow = false
                goal.addChildNode(center)
                goal.constraints = [SCNBillboardConstraint()]
                if let title, !title.isEmpty {
                    let label = RoomObjectLabel(title: title, symbol: "flag.fill", tint: .systemBlue)
                    label.isUserInteractionEnabled = false
                    label.accessibilityTraits = .staticText
                    addSubview(label)
                    destinationLabel = label
                }
            }
        }
        self.floorY = floorY
        self.destination = target
        self.destinationTitle = title
        goal.isHidden = target == nil
        if let target { goal.simdPosition = SIMD3(target.x, floorY + 0.035, target.y) }
        refreshAccessibility()
    }

    private func mapInk(_ color: UIColor, opacity: CGFloat = 1) -> SCNMaterial {
        let ink = SCNMaterial()
        ink.lightingModel = .constant
        ink.diffuse.contents = color
        ink.transparency = opacity
        ink.isDoubleSided = true
        return ink
    }

    private func routeRibbon(_ points: [SIMD2<Float>], width: Float, altitude: Float, color: UIColor) -> SCNNode {
        var positions: [SCNVector3] = []
        var indices: [UInt32] = []
        for (start, end) in zip(points, points.dropFirst()) {
            let delta = end - start
            guard simd_length_squared(delta) > 0.000001 else { continue }
            let direction = simd_normalize(delta)
            let normal = SIMD2(-direction.y, direction.x) * width / 2
            let offset = UInt32(positions.count)
            for point in [start + normal, end + normal, start - normal, end - normal] {
                positions.append(SCNVector3(point.x, altitude, point.y))
            }
            indices.append(contentsOf: [offset, offset + 1, offset + 2, offset + 1, offset + 3, offset + 2])
        }
        for point in points {
            let offset = UInt32(positions.count)
            positions.append(SCNVector3(point.x, altitude, point.y))
            for step in 0..<12 {
                let angle = Float(step) * .pi / 6
                positions.append(SCNVector3(point.x + cos(angle) * width / 2, altitude, point.y + sin(angle) * width / 2))
                indices.append(contentsOf: [offset, offset + UInt32((step + 1) % 12) + 1, offset + UInt32(step) + 1])
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: positions)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [mapInk(color)]
        let node = SCNNode(geometry: geometry)
        node.categoryBitMask = 32
        node.castsShadow = false
        return node
    }

    private func refreshAccessibility() {
        var elements: [Any] = [canvas]
        if isNavigating {
            if userPosition != nil { elements.append(locationDot) }
            if let destinationLabel { elements.append(destinationLabel) }
        } else { elements.append(contentsOf: labels.map(\.view)) }
        accessibilityElements = elements
    }

    private func fitBounds(_ source: ProcessedScene) {
        var points = source.objects.flatMap(\.obstacleCorners).compactMap(vector)
        for floor in measuredFloors {
            points.append(contentsOf: floor.corners.map { SIMD3($0.x, floor.bottom ?? floorY, $0.y) })
        }
        for surface in source.surfaces where ["floor", "wall"].contains(surface.kind) {
            guard let pose = matrix(surface.mapFromSurface), var size = vector(surface.renderDimensionsM) else { continue }
            var center = SIMD3<Float>.zero
            if surface.kind == "wall" && !fullWalls {
                let height = size.y
                size.y = flat ? min(0.12, height) : min(1.05, height)
                center.y = (size.y - height) / 2
            }
            points.append(contentsOf: corners(size, center: center).map { transformed($0, by: pose) })
        }
        if !details.isHidden {
            points.append(contentsOf: source.meshes.flatMap(\.vertices).compactMap(vector))
            points.append(contentsOf: source.pointCloud.compactMap { vector($0.position) })
        }
        if isNavigating {
            points.append(contentsOf: routePoints.map { SIMD3($0.x, floorY, $0.y) })
            if let userPosition { points.append(SIMD3(userPosition.x, floorY, userPosition.y)) }
            if let destination { points.append(SIMD3(destination.x, floorY + 0.45, destination.y)) }
        }
        guard let first = points.first else { lower = SIMD3(repeating: -0.5); upper = SIMD3(repeating: 0.5); return }
        lower = first
        upper = first
        for point in points { lower = simd_min(lower, point); upper = simd_max(upper, point) }
        lower.y -= 0.18
        let center = (lower + upper) / 2
        sun.simdPosition = center + SIMD3(5, 10, -5)
        sun.look(at: scn(center))
        sun.light?.orthographicScale = CGFloat(max(10, max(upper.x - lower.x, upper.z - lower.z) * 1.4))
    }

    private func updateCamera() {
        let viewport = canvas.bounds.size
        guard viewport.width > 0, viewport.height > 0, let projection = camera.camera else { return }
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        let center = (lower + upper) / 2
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let up = simd_normalize(simd_cross(towardsCamera, right))
        var width: Float = 0.5
        var height: Float = 0.5
        for point in corners(upper - lower, center: center) {
            let delta = point - center
            width = max(width, 2 * abs(simd_dot(delta, right)))
            height = max(height, 2 * abs(simd_dot(delta, up)))
        }
        let available = max(120, viewport.height - min(bottomInset, viewport.height - 120))
        let fraction = Float(available / viewport.height)
        let aspect = Float(viewport.width / viewport.height)
        let scale = max(height / (fraction * 0.88), width / (aspect * 0.96)) / (2 * zoom)
        projection.orthographicScale = Double(scale)
        let target = center - up * scale * Float((viewport.height - available) / viewport.height)
        camera.simdPosition = target + towardsCamera * max(8, simd_length(upper - lower) * 2)
        camera.look(at: scn(target), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        let metersPerPoint = 2 * scale / Float(viewport.height)
        goal.simdScale = SIMD3(repeating: min(3, max(0.5, metersPerPoint * 26 / 0.44)))
        positionLabels()
    }

    private func buildLabels(_ source: ProcessedScene) {
        labels.forEach { $0.view.removeFromSuperview() }
        labels = []
        let items = source.objects.filter { !["rug", "carpet"].contains($0.sourceCategory.lowercased()) }
        for object in items.prefix(6) {
            guard let minimum = vector(object.obstacleBounds.min), let maximum = vector(object.obstacleBounds.max) else { continue }
            let label = RoomObjectLabel(title: RoomItemStyle.title(object.sourceCategory),
                                        symbol: RoomItemStyle.symbol(object.sourceCategory),
                                        tint: UIColor(RoomItemStyle.tint(object.sourceCategory)))
            label.onTap = { [weak self] in self?.onSelection?(object.sourceID) }
            addSubview(label)
            labels.append((object.sourceID, SIMD3((minimum.x + maximum.x) / 2, maximum.y + 0.03, (minimum.z + maximum.z) / 2), label))
        }
        refreshAccessibility()
    }

    @objc private func positionLabels() {
        guard bounds.width > 0 else { return }
        var occupied: [CGRect] = []
        let sorted = labels.sorted { ($0.id == selection ? 0 : 1) < ($1.id == selection ? 0 : 1) }
        for label in sorted {
            label.view.isSelected = label.id == selection
            let point = canvas.projectPoint(scn(label.position))
            let size = label.view.intrinsicContentSize
            let frame = CGRect(x: CGFloat(point.x) - size.width / 2, y: CGFloat(point.y) - size.height - 5, width: size.width, height: size.height)
            let allowed = CGRect(x: 5, y: 28, width: bounds.width - 10, height: max(1, bounds.height - bottomInset - 40))
            let hidden = !labelsVisible || point.z < 0 || point.z > 1 || !allowed.contains(frame) || occupied.contains { $0.intersects(frame.insetBy(dx: -3, dy: -3)) }
            label.view.isHidden = hidden
            label.view.frame = frame
            if !hidden { occupied.append(frame) }
        }
        if let userPosition {
            let point = canvas.projectPoint(scn(SIMD3(userPosition.x, floorY + 0.065, userPosition.y)))
            locationDot.frame = CGRect(x: CGFloat(point.x) - 8, y: CGFloat(point.y) - 8, width: 16, height: 16)
            locationDot.isHidden = !isNavigating || point.z < 0 || point.z > 1 || !bounds.contains(locationDot.center)
            bringSubviewToFront(locationDot)
        } else { locationDot.isHidden = true }
        if let label = destinationLabel, let destination {
            let position = SIMD3(destination.x, floorY + 0.44 * goal.simdScale.y + 0.03, destination.y)
            let point = canvas.projectPoint(scn(position))
            let size = label.intrinsicContentSize
            label.frame = CGRect(x: CGFloat(point.x) - size.width / 2, y: CGFloat(point.y) - size.height - 2, width: size.width, height: size.height)
            label.isHidden = !isNavigating || point.z < 0 || point.z > 1 || !bounds.intersects(label.frame)
            bringSubviewToFront(label)
        }
    }

    private func buildSelection() {
        highlight.childNodes.forEach { $0.removeFromParentNode() }
        guard let object = source?.objects.first(where: { $0.sourceID == selection }), let size = vector(object.measuredDimensionsM),
              let pose = matrix(object.mapFromObject), let minimum = vector(object.obstacleBounds.min) else { return }
        let width = CGFloat(size.x + 0.13)
        let depth = CGFloat(size.z + 0.13)
        let outer = UIBezierPath(roundedRect: CGRect(x: -width / 2, y: -depth / 2, width: width, height: depth), cornerRadius: 0.13)
        let inner = UIBezierPath(roundedRect: CGRect(x: -width / 2 + 0.026, y: -depth / 2 + 0.026, width: width - 0.052, height: depth - 0.052), cornerRadius: 0.105)
        outer.append(inner.reversing())
        let shape = SCNShape(path: outer, extrusionDepth: 0.003)
        let accent = SCNMaterial()
        accent.lightingModel = .constant
        accent.diffuse.contents = UIColor(roomHex: "#939e9a")
        shape.materials = [accent]
        let ring = SCNNode(geometry: shape)
        ring.eulerAngles.x = -.pi / 2
        let parent = SCNNode()
        parent.eulerAngles.y = atan2(pose.columns.2.x, pose.columns.2.z)
        parent.simdPosition = SIMD3(pose.columns.3.x, minimum.y + 0.018, pose.columns.3.z)
        parent.categoryBitMask = 2
        ring.categoryBitMask = 2
        ring.castsShadow = false
        parent.addChildNode(ring)
        highlight.addChildNode(parent)
    }

    @objc private func selectObject(_ gesture: UITapGestureRecognizer) {
        guard !isNavigating else { return }
        let hits = canvas.hitTest(gesture.location(in: canvas), options: [.categoryBitMask: 1, .searchMode: SCNHitTestSearchMode.all.rawValue])
        for hit in hits {
            var node: SCNNode? = hit.node
            while let candidate = node {
                if let name = candidate.name, name.hasPrefix("object:") { onSelection?(String(name.dropFirst(7))); return }
                node = candidate.parent
            }
        }
        onSelection?(nil)
    }

    private func resetOrbit() { yaw = .pi * 3 / 4; pitch = 0.68; zoom = 1 }

    @objc private func orbit(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: canvas)
        yaw -= Float(delta.x) * 0.007
        if !flat { pitch = min(1.3, max(0.28, pitch + Float(delta.y) * 0.005)) }
        gesture.setTranslation(.zero, in: canvas)
        updateShellIfNeeded()
        updateCamera()
    }

    @objc private func magnify(_ gesture: UIPinchGestureRecognizer) {
        zoom = min(3.2, max(0.65, zoom * Float(gesture.scale)))
        gesture.scale = 1
        updateCamera()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }

    @objc private func rotateLeft() -> Bool { yaw += .pi / 8; updateShellIfNeeded(); updateCamera(); return true }
    @objc private func rotateRight() -> Bool { yaw -= .pi / 8; updateShellIfNeeded(); updateCamera(); return true }
    @objc private func zoomIn() -> Bool { zoom = min(3.2, zoom * 1.2); updateCamera(); return true }
    @objc private func zoomOut() -> Bool { zoom = max(0.65, zoom / 1.2); updateCamera(); return true }
    @objc private func resetView() -> Bool { resetOrbit(); updateShellIfNeeded(); updateCamera(); return true }

    private func vector(_ values: [Float]) -> SIMD3<Float>? {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private func matrix(_ values: [Float]) -> simd_float4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15])
        ))
    }

    private func corners(_ size: SIMD3<Float>, center: SIMD3<Float>) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        for x: Float in [-0.5, 0.5] { for y: Float in [-0.5, 0.5] { for z: Float in [-0.5, 0.5] {
            result.append(center + size * SIMD3(x, y, z))
        } } }
        return result
    }
    private func transformed(_ point: SIMD3<Float>, by pose: simd_float4x4) -> SIMD3<Float> {
        let result = pose * SIMD4(point.x, point.y, point.z, 1)
        return SIMD3(result.x, result.y, result.z)
    }
    private func array(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }
    private func scn(_ value: SIMD3<Float>) -> SCNVector3 { SCNVector3(value.x, value.y, value.z) }
}

@MainActor
private final class RoomObjectLabel: UIControl {
    var onTap: (() -> Void)?
    private let icon = UIImageView()
    private let title = UILabel()
    private let itemTint: UIColor

    init(title text: String, symbol: String, tint: UIColor) {
        itemTint = tint
        super.init(frame: .zero)
        icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.backgroundColor = itemTint
        icon.layer.cornerRadius = 9
        addSubview(icon)
        title.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: itemTint,
            .strokeColor: UIColor(roomHex: "#fafbf8"), .strokeWidth: -4
        ])
        title.layer.shadowColor = UIColor.white.cgColor
        title.layer.shadowOpacity = 0.7
        title.layer.shadowRadius = 2
        title.layer.shadowOffset = .zero
        addSubview(title)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(title:symbol:)") }

    override var intrinsicContentSize: CGSize { CGSize(width: title.intrinsicContentSize.width + 25, height: 28) }
    override var isSelected: Bool {
        didSet {
            icon.backgroundColor = itemTint
            icon.layer.borderWidth = isSelected ? 1.5 : 0
            icon.layer.borderColor = UIColor.white.cgColor
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 0, y: 5, width: 18, height: 18)
        title.frame = CGRect(x: 23, y: 0, width: max(0, bounds.width - 23), height: 28)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { bounds.insetBy(dx: -5, dy: -8).contains(point) }
    @objc private func tapped() { onTap?() }
}

private extension UIColor {
    convenience init(roomHex: String) {
        let digits = roomHex.hasPrefix("#") ? String(roomHex.dropFirst()) : roomHex
        let value = UInt32(digits, radix: 16) ?? 0xb6c6c3
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
