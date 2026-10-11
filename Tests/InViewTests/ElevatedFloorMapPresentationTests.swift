import AccessCore
import SceneKit
import simd
import XCTest
@testable import InView

@MainActor
final class ElevatedFloorMapPresentationTests: XCTestCase {
    private func denseFloors() -> [Footprint] {
        (0..<2_048).map { index in
            let x = Float(index % 32), z = Float(index / 32)
            return Footprint(floor: [[x, z], [x + 0.5, z], [x, z + 0.5]], bottom: index < 1_024 ? 0 : 1.2)
        }
    }

    private func updateDenseFloor(_ view: RoomMapRenderView, floors: [Footprint]) {
        let scene = ProcessedScene(sourceScanID: "dense-floor-preview", mapID: "dense-floor-preview",
                                   floorID: "floor-1", objects: [], surfaces: [], meshes: [])
        view.update(scene, selectedObjectID: nil, showsLabels: false, floorFootprints: floors,
            topDown: false, resetID: 0, showsDetails: false, showsFullWalls: false,
            viewportBottomInset: 0, viewportTopInset: 0, routePoints: [], userPosition: nil,
            userHeading: nil, floorY: 0, destination: nil, destinationTitle: nil, isNavigating: true)
    }

    private func zone(_ id: String, elevation: Float, minimum: SIMD2<Float>, maximum: SIMD2<Float>,
                      points: [AccessPoint] = []) -> ElevatedFloorZone {
        let floor = Footprint(floor: [minimum, SIMD2(maximum.x, minimum.y), maximum,
                                      SIMD2(minimum.x, maximum.y)], bottom: elevation)
        return ElevatedFloorZone(id: id, map: VenueMap(floorY: elevation, footprints: [floor], points: points))
    }

    func testRayPickingUsesTheNearestMeasuredElevation() throws {
        let map = ElevatedFloorMap(displayFloor: 1, zones: [
            zone("main", elevation: 0, minimum: [-10, -10], maximum: [10, 10]),
            zone("auditorium", elevation: 1, minimum: [2, -1], maximum: [4, 1])
        ], connectors: [])
        let raised = try XCTUnwrap(ElevatedFloorMapPresentation.pick(on: map,
            rayStart: [0.5, 5, 0], rayEnd: [5.5, -5, 0]))
        XCTAssertEqual(raised.zoneID, "auditorium")
        XCTAssertEqual(raised.position, SIMD3(2.5, 1, 0), "An angled pick must intersect the raised surface, not the main-floor plane")
        let main = try XCTUnwrap(ElevatedFloorMapPresentation.pick(on: map,
            rayStart: [-3, 5, 0], rayEnd: [-3, -5, 0]))
        XCTAssertEqual(main.zoneID, "main")
        XCTAssertEqual(main.position.y, 0)
        XCTAssertNil(ElevatedFloorMapPresentation.pick(on: map, rayStart: [20, 5, 0], rayEnd: [20, -5, 0]),
                     "A completed visual shell cannot make unmeasured space selectable")
        XCTAssertNil(ElevatedFloorMapPresentation.pick(on: map, rayStart: [0, 5, 0], rayEnd: [1, 5, 0]))
    }

    func testMarkersKeepTheirZoneAndLegacyFloorHeight() {
        let main = zone("main", elevation: 0, minimum: [-2, -2], maximum: [2, 2])
        let upper = zone("auditorium", elevation: 1, minimum: [-2, -2], maximum: [2, 2])
        let map = ElevatedFloorMap(displayFloor: 1, zones: [main, upper], connectors: [])
        let location = ElevatedFloorLocation(zoneID: "auditorium", position: [0, 1, 0])
        XCTAssertEqual(ElevatedFloorMapPresentation.markerPosition(.zero, location: location,
            fallback: nil, map: map, floorY: 0), SIMD3(0, 1, 0))
        XCTAssertNil(ElevatedFloorMapPresentation.markerPosition(.zero, location: nil,
            fallback: nil, map: map, floorY: 0), "Overlapping levels require an explicit zone")
        XCTAssertEqual(ElevatedFloorMapPresentation.markerPosition(.zero, location: location,
            fallback: nil, map: nil, floorY: 4), SIMD3(0, 4, 0), "Legacy maps retain their existing plane")
    }

    func testRenderedSurfaceRibbonsDoNotBridgeTheLevelTransition() throws {
        let destination = AccessPoint(kind: .destination, name: "Auditorium", position: [17, 1.2, 5], source: .manual, confidence: 1)
        let zones = [zone("main", elevation: 0, minimum: [0, 0], maximum: [10, 10]),
                     zone("auditorium", elevation: 1.2, minimum: [10, 0], maximum: [20, 10], points: [destination])]
        let connector = ElevatedFloorConnector(id: "auditorium-elevator", kind: .elevator,
            from: ElevatedFloorLocation(zoneID: "main", position: [8, 0, 5]),
            to: ElevatedFloorLocation(zoneID: "auditorium", position: [12, 1.2, 5]),
            availability: .available, stepFree: true, minimumClearWidthMeters: 1.2, estimatedSeconds: 20)
        let map = ElevatedFloorMap(displayFloor: 1, zones: zones, connectors: [connector])
        let route = try XCTUnwrap(try ElevatedFloorRoutePlanner(map: map).route(
            from: ElevatedFloorLocation(zoneID: "main", position: [3, 0, 5]), to: destination.id))
        let paths = ElevatedFloorMapPresentation.surfacePaths(in: route)
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].last, connector.from.position)
        XCTAssertEqual(paths[1].first, connector.to.position)

        let view = RoomMapRenderView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        view.layoutIfNeeded()
        let scene = ProcessedScene(sourceScanID: "floor-1-preview", mapID: "floor-1-preview",
                                   floorID: "floor-1", objects: [], surfaces: [], meshes: [])
        view.update(scene, selectedObjectID: nil, showsLabels: false,
            floorFootprints: zones.flatMap { $0.map.footprints }, topDown: false, resetID: 0,
            showsDetails: false, showsFullWalls: false, viewportBottomInset: 210, viewportTopInset: 110,
            routePoints: [], userPosition: nil, userHeading: nil, floorY: 0, destination: nil,
            destinationTitle: destination.title, isNavigating: true, elevatedMap: map, elevatedRoute: route)
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? SCNView }.first)
        let root = try XCTUnwrap(canvas.scene?.rootNode)
        let lower = try XCTUnwrap(root.childNode(withName: "elevated-route-surface-0", recursively: true))
        let raised = try XCTUnwrap(root.childNode(withName: "elevated-route-surface-1", recursively: true))
        XCTAssertEqual(lower.boundingBox.min.y, 0.026, accuracy: 0.001)
        XCTAssertEqual(lower.boundingBox.max.y, 0.026, accuracy: 0.001)
        XCTAssertEqual(raised.boundingBox.min.y, 1.226, accuracy: 0.001)
        XCTAssertEqual(raised.boundingBox.max.y, 1.226, accuracy: 0.001)
        XCTAssertLessThan(lower.boundingBox.max.x, raised.boundingBox.min.x,
                          "The elevator landings must remain separate ribbons")
    }

    func testArbitraryEndpointsKeepTheirHeightsAcrossAnExplicitRamp() throws {
        let start = ElevatedFloorLocation(zoneID: "main", position: [3, 0, 5])
        let destination = ElevatedFloorLocation(zoneID: "terrace", position: [31, 1.2, 5])
        let ramp = ElevatedFloorConnector(id: "terrace-ramp", kind: .ramp,
            from: ElevatedFloorLocation(zoneID: "main", position: [8, 0, 5]),
            to: ElevatedFloorLocation(zoneID: "terrace", position: [26, 1.2, 5]),
            availability: .available, stepFree: true, minimumClearWidthMeters: 1.2,
            slopeDegrees: 4, estimatedSeconds: 25)
        let map = ElevatedFloorMap(displayFloor: 1, zones: [
            zone("main", elevation: 0, minimum: [0, 0], maximum: [10, 10]),
            zone("terrace", elevation: 1.2, minimum: [24, 0], maximum: [34, 10])
        ], connectors: [ramp])
        let route = try XCTUnwrap(try ElevatedFloorRoutePlanner(map: map).route(from: start, to: destination))
        let paths = ElevatedFloorMapPresentation.surfacePaths(in: route)
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths[0].first, start.position)
        XCTAssertEqual(paths[1], [ramp.from.position, ramp.to.position],
                       "Only an explicit physical ramp adds a sloped walk segment")
        XCTAssertEqual(paths[2].last, destination.position)
        XCTAssertEqual(ElevatedFloorMapPresentation.markerPosition(destination.floorPoint, location: destination,
            fallback: route.destination.position, map: map, floorY: 0), destination.position)
    }

    func testDenseMeasuredTrianglesUseBoundedBatchesWithoutFillingGaps() throws {
        let floors = denseFloors()
        let view = RoomMapRenderView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        updateDenseFloor(view, floors: floors)
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? SCNView }.first)
        let shell = try XCTUnwrap(canvas.scene?.rootNode.childNode(withName: "measured-floors", recursively: true))
        XCTAssertEqual(shell.childNodes.count, 2, "Thousands of capture triangles must not become thousands of draw commands")
        let geometries = shell.childNodes.compactMap(\.geometry)
        XCTAssertEqual(geometries.count, 2)
        XCTAssertTrue(geometries.allSatisfy { ($0.sources(for: .vertex).first?.vectorCount ?? .max) <= 30_000 })
        XCTAssertTrue(geometries.allSatisfy { $0.elements.count == 2 })
        XCTAssertEqual(Set(geometries.flatMap(\.materials).map(ObjectIdentifier.init)).count, 2)
        XCTAssertEqual(shell.boundingBox.min.y, -0.18, accuracy: 0.001)
        XCTAssertEqual(shell.boundingBox.max.y, 1.2, accuracy: 0.001)
        XCTAssertEqual(shell.boundingBox.min.x, 0, accuracy: 0.001)
        XCTAssertEqual(shell.boundingBox.max.x, 31.5, accuracy: 0.001)
        XCTAssertEqual(shell.boundingBox.max.z, 63.5, accuracy: 0.001)
        let map = ElevatedFloorMap(displayFloor: 1, zones: [
            ElevatedFloorZone(id: "main", map: VenueMap(floorY: 0, footprints: Array(floors.prefix(1_024)), points: [])),
            ElevatedFloorZone(id: "raised", map: VenueMap(floorY: 1.2, footprints: Array(floors.suffix(1_024)), points: []))
        ], connectors: [])
        XCTAssertNotNil(ElevatedFloorMapPresentation.pick(on: map, rayStart: [0.1, 5, 0.1], rayEnd: [0.1, -5, 0.1]))
        XCTAssertNil(ElevatedFloorMapPresentation.pick(on: map, rayStart: [0.9, 5, 0.9], rayEnd: [0.9, -5, 0.9]),
                     "Batching must retain measured gaps instead of filling the enclosing rectangle")
    }

    func testRequestedIllustrationSkipsTransientDenseFloorAndRestoresFallbackOnFailure() async throws {
        let view = RoomMapRenderView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let failed = expectation(description: "Missing illustration falls back to measured geometry")
        view.onIllustrationState = { if $0 == .failed { failed.fulfill() } }
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("missing-\(UUID()).usdz")
        view.updateIllustration(url: missing, transform: matrix_identity_float4x4, shown: true, showsScanOutline: false)
        updateDenseFloor(view, floors: denseFloors())
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? SCNView }.first)
        let floors = try XCTUnwrap(canvas.scene?.rootNode.childNode(withName: "measured-floors", recursively: true))
        XCTAssertTrue(floors.childNodes.isEmpty, "The first loading frame must not build the measured floor underneath")
        XCTAssertEqual(floors.parent?.isHidden, true)
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(floors.childNodes.count, 2, "An illustration failure must restore the bounded measured floor")
        XCTAssertEqual(floors.parent?.isHidden, false)
    }
}
