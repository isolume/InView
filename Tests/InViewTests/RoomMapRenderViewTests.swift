import AccessCore
import SceneKit
import XCTest
@testable import InView

@MainActor
final class RoomMapRenderViewTests: XCTestCase {
    private func makeMap() throws -> (RoomMapRenderView, ProcessedScene, SCNView) {
        let scene = try XCTUnwrap(StudentCenterCatalog.scene())
        let view = RoomMapRenderView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        view.layoutIfNeeded()
        update(view, scene: scene)
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? SCNView }.first)
        return (view, scene, canvas)
    }

    private func update(_ view: RoomMapRenderView, scene: ProcessedScene,
                        floorFootprints: [Footprint] = [], showsDetails: Bool = false) {
        view.update(scene, selectedObjectID: nil, showsLabels: false, floorFootprints: floorFootprints,
                    topDown: false, resetID: 0, showsDetails: showsDetails, showsFullWalls: false,
                    viewportBottomInset: 210, viewportTopInset: 110, routePoints: [],
                    userPosition: nil, userHeading: nil, floorY: 0, destination: nil,
                    destinationTitle: nil, isNavigating: true)
    }

    private func floorShapes(_ canvas: SCNView) -> Set<ObjectIdentifier> {
        var result = Set<ObjectIdentifier>()
        canvas.scene?.rootNode.enumerateChildNodes { node, _ in
            if node.categoryBitMask == 4, let geometry = node.geometry as? SCNShape {
                result.insert(ObjectIdentifier(geometry))
            }
        }
        return result
    }

    func testUnchangedUpdatesLeaveCameraUntouched() throws {
        let (view, scene, canvas) = try makeMap()
        let camera = try XCTUnwrap(canvas.pointOfView?.camera)
        var changes = 0
        let observation = camera.observe(\.orthographicScale) { _, _ in changes += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<240 { update(view, scene: scene) }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print("MAP_PERFORMANCE unchanged_updates_ms=\(milliseconds)")
        withExtendedLifetime(observation) { XCTAssertEqual(changes, 0) }
    }

    func testRotatingKeepsMeasuredFloorGeometry() throws {
        let (view, _, canvas) = try makeMap()
        let floors = floorShapes(canvas)
        XCTAssertFalse(floors.isEmpty)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<48 {
            _ = view.perform(NSSelectorFromString("rotateLeft"))
            XCTAssertEqual(floorShapes(canvas), floors, "Camera movement must not recreate measured floor slabs")
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        print("MAP_PERFORMANCE rotations_ms=\(milliseconds)")
    }
    func testDiagonalDetailKeepsTheFloorFraming() throws {
        let axis = SIMD2<Float>(repeating: 1 / sqrt(2))
        let cross = SIMD2(-axis.y, axis.x)
        let along = axis * Float(50)
        let across = cross * Float(0.5)
        let corners: [SIMD2<Float>] = [-along - across, along - across, along + across, -along + across]
        let mesh = SceneMesh(sourceID: "diagonal-detail",
                             vertices: corners.map { [$0.x, 0, $0.y] },
                             triangles: [[0, 1, 2], [0, 2, 3]])
        let scene = ProcessedScene(sourceScanID: "detail-framing", mapID: "detail-framing",
                                   floorID: "detail-framing", objects: [], surfaces: [], meshes: [mesh])
        let floors = [Footprint(floor: corners, bottom: 0)]
        let view = RoomMapRenderView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        view.initialYaw = .pi / 4
        view.layoutIfNeeded()
        update(view, scene: scene, floorFootprints: floors)
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? SCNView }.first)
        let camera = try XCTUnwrap(canvas.pointOfView?.camera)
        let floorScale = camera.orthographicScale
        update(view, scene: scene, floorFootprints: floors, showsDetails: true)
        XCTAssertTrue(camera.orthographicScale.isFinite)
        XCTAssertLessThanOrEqual(camera.orthographicScale, floorScale * 1.05,
                                 "Showing diagonal scan evidence must not frame empty map-axis corners")
    }

}
