import AccessCore
import SceneKit
import XCTest
@testable import InView

final class Floor2RoutingTests: XCTestCase {
    private func resource(_ name: String, extension suffix: String = "json") throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: suffix, subdirectory: "StudentCenter")
            ?? Bundle.main.url(forResource: name, withExtension: suffix))
    }

    private func load(_ name: String) throws -> VenueMap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VenueMap.self, from: Data(contentsOf: resource(name)))
    }

    private func isFloorMesh(_ node: SCNNode?) -> Bool {
        guard let node else { return false }
        let name = node.name?.lowercased() ?? ""
        return name.hasSuffix("continuous_tile_floor") || name.hasSuffix("lounge_carpet")
            || isFloorMesh(node.parent)
    }

    private func floorTriangles(map: VenueMap) throws -> [[SIMD2<Float>]] {
        let scene = try SCNScene(url: resource("student-center-east-floor-2-model", extension: "usdz"))
        let registration = try XCTUnwrap(StudentCenterModelAlignment.transform(for: map))
        var nodes: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in nodes.append(node) }
        var triangles: [[SIMD2<Float>]] = []
        for node in nodes where isFloorMesh(node) {
            guard let geometry = node.geometry, let source = geometry.sources(for: .vertex).first else { continue }
            _ = try XCTUnwrap(source.usesFloatComponents && source.bytesPerComponent == 4
                && source.componentsPerVector >= 3 ? true : nil, "Unsupported floor vertex encoding")
            let transform = registration * node.simdWorldTransform
            let vertices: [SIMD3<Float>] = source.data.withUnsafeBytes { bytes in
                (0..<source.vectorCount).map { index in
                    let offset = source.dataOffset + index * source.dataStride
                    let p = SIMD4<Float>(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                        bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                        bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self), 1)
                    let world = transform * p
                    return SIMD3(world.x, world.y, world.z)
                }
            }
            let sourceIndex = try XCTUnwrap(geometry.sources.firstIndex { $0 === source })
            let channel = geometry.geometrySourceChannels?[sourceIndex].intValue ?? 0
            for element in geometry.elements {
                _ = try XCTUnwrap([1, 2, 4].contains(element.bytesPerIndex) ? true : nil)
                let values: [Int] = element.data.withUnsafeBytes { bytes in
                    (0..<(element.data.count / element.bytesPerIndex)).map { index in
                        let offset = index * element.bytesPerIndex
                        switch element.bytesPerIndex {
                        case 1: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                        case 2: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                        default: return Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        }
                    }
                }
                let faceSizes: [Int]
                let dataOffset: Int
                switch element.primitiveType {
                case .triangles:
                    faceSizes = Array(repeating: 3, count: element.primitiveCount)
                    dataOffset = 0
                case .polygon:
                    // USDZ imports store polygon sizes first, followed by one
                    // or more position/normal index channels in the same data.
                    faceSizes = Array(values.prefix(element.primitiveCount))
                    dataOffset = element.primitiveCount
                default:
                    continue
                }
                let indexCount = faceSizes.reduce(0, +)
                let channels = element.indicesChannelCount
                _ = try XCTUnwrap(channels > channel && values.count >= dataOffset + indexCount * channels
                    ? true : nil, "Invalid floor polygon index data")
                var cursor = 0
                for faceSize in faceSizes {
                    let points = try (0..<faceSize).map { corner -> SIMD3<Float> in
                        let offset = element.hasInterleavedIndicesChannels
                            ? (cursor + corner) * channels + channel
                            : channel * indexCount + cursor + corner
                        let index = values[dataOffset + offset]
                        return try XCTUnwrap(vertices.indices.contains(index) ? vertices[index] : nil)
                    }
                    cursor += faceSize
                    guard points.allSatisfy({ abs($0.y - map.floorY) < 0.02 }) else { continue }
                    _ = try XCTUnwrap(points.count == 3 ? true : nil,
                        "Exported floor top faces must be triangulated")
                    triangles.append(points.map { SIMD2($0.x, $0.z) })
                }
            }
        }
        return try XCTUnwrap(triangles.count > 50 ? triangles : nil,
            "Expected actual bundled floor triangles; stop before testing route samples")
    }

    private func contains(_ p: SIMD2<Float>, triangle: [SIMD2<Float>]) -> Bool {
        func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
        let edges = (0..<3).map { i in cross(triangle[(i + 1) % 3] - triangle[i], p - triangle[i]) }
        return edges.allSatisfy { $0 >= -0.0001 } || edges.allSatisfy { $0 <= 0.0001 }
    }

    private func distance(_ point: SIMD2<Float>, to a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let edge = b - a
        let t = min(1, max(0, simd_dot(point - a, edge) / simd_length_squared(edge)))
        return simd_distance(point, a + edge * t)
    }

    func testLoungeRoutesStayOnTheBundledFloorAtStepFreeClearance() throws {
        let map = try load("student-center-east-floor-2-navigation")
        XCTAssertTrue(StudentCenterCatalog.isDisplayable(map))
        let triangles = try floorTriangles(map: map)
        let transform = try XCTUnwrap(StudentCenterModelAlignment.transform(for: map))
        let lounge = try XCTUnwrap(StudentCenterCatalog.modelLandmarks(for: 2).first { $0.title == "Lounge" })
        let position = transform * SIMD4(lounge.position.x, 0, lounge.position.z, 1)
        let starts = [SIMD2(position.x, position.z), SIMD2<Float>(12.827781, -7.452379)]
        // The measured balcony edge in the same canonical map coordinates.
        // Source principalUV runs from (-21.15, -7.25) to (19.42, -7.25).
        let balconyA = SIMD2<Float>(37.198100, -2.201427)
        let balconyB = SIMD2<Float>(-2.801309, 4.578849)
        let planner = RoutePlanner(map: map)
        let elevators = map.points.filter { $0.kind == .elevator }
        XCTAssertEqual(elevators.count, 2)
        for start in starts {
            for elevator in elevators {
                let route = try XCTUnwrap(planner.route(from: start, to: elevator,
                    conditions: RoutePreference.stepFree.navigationConditions(map: map)), "Known lounge route must remain available")
                XCTAssertGreaterThanOrEqual(route.clearance, 0.45)
                XCTAssertGreaterThan(route.length, 20)
                let grid = OccupancyGrid(map: map, clearance: route.clearance)
                for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) {
                    let count = max(1, Int(ceil(simd_distance(a, b) / 0.01)))
                    for i in 0...count {
                        let point = a + (b - a) * (Float(i) / Float(count))
                        XCTAssertTrue(triangles.contains { contains(point, triangle: $0) },
                                      "\(elevator.title) leaves visible floor at \(point)")
                        XCTAssertGreaterThanOrEqual(distance(point, to: balconyA, balconyB), 0.45,
                                                    "Route approaches exposed balcony edge")
                        let cell = try XCTUnwrap(grid.index(containing: point))
                        XCTAssertFalse(grid.isBlocked(cell), "Route crosses inflated obstacle")
                    }
                }
            }
        }
    }

    func testNavigationDoesNotRestoreUnmappedAtriumShortcuts() throws {
        let map = try load("student-center-east-floor-2-navigation")
        for preference in [RoutePreference.stepFree, .fastest] {
            XCTAssertFalse(preference.navigationConditions(map: map).allowsUnmappedSpace)
            XCTAssertTrue(preference.navigationConditions().allowsUnmappedSpace,
                          "Other maps retain their existing fallback behavior")
        }
    }

    func testNavigationRetainsTheMeasuredAccessPointsAndObstacles() throws {
        let original = try load("student-center-east-floor-2")
        let navigation = try load("student-center-east-floor-2-navigation")
        XCTAssertEqual(navigation.points, original.points)
        XCTAssertEqual(navigation.floorY, original.floorY)
        XCTAssertEqual(navigation.footprints.filter { $0.kind != .floor }, original.footprints.filter { $0.kind != .floor })
        XCTAssertEqual(navigation.requiresMeasuredFloorCoverage, true)
    }
}
