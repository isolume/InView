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

    private struct FloorTriangle {
        let a: SIMD2<Float>
        let b: SIMD2<Float>
        let c: SIMD2<Float>
        let lower: SIMD2<Float>
        let upper: SIMD2<Float>

        init(_ corners: [SIMD2<Float>]) {
            a = corners[0]; b = corners[1]; c = corners[2]
            lower = simd_min(a, simd_min(b, c)) - SIMD2(repeating: 0.0001)
            upper = simd_max(a, simd_max(b, c)) + SIMD2(repeating: 0.0001)
        }

        func contains(_ point: SIMD2<Float>) -> Bool {
            guard point.x >= lower.x, point.x <= upper.x,
                  point.y >= lower.y, point.y <= upper.y else { return false }
            func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }
            let ab = cross(b - a, point - a)
            let bc = cross(c - b, point - b)
            let ca = cross(a - c, point - c)
            return (ab >= -0.0001 && bc >= -0.0001 && ca >= -0.0001)
                || (ab <= 0.0001 && bc <= 0.0001 && ca <= 0.0001)
        }
    }

    private func distance(_ point: SIMD2<Float>, to a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let edge = b - a
        let t = min(1, max(0, simd_dot(point - a, edge) / simd_length_squared(edge)))
        return simd_distance(point, a + edge * t)
    }

    private func registeredLandmarks(map: VenueMap) throws -> [AccessPoint] {
        let transform = try XCTUnwrap(StudentCenterModelAlignment.transform(for: map))
        let elevation = try XCTUnwrap(StudentCenterCatalog.modelFloorY(for: 2))
        return StudentCenterCatalog.modelLandmarks(for: 2).map { landmark in
            let position = transform * SIMD4(landmark.position.x, elevation, landmark.position.z, 1)
            return AccessPoint(id: landmark.id, kind: landmark.title == "Lifts" ? .elevator : .destination,
                               name: landmark.title, position: SIMD3(position.x, position.y, position.z),
                               source: .manual, confidence: 0.5)
        }
    }

    private func navigationTriangles(map: VenueMap) throws -> [FloorTriangle] {
        let floors = map.footprints.filter { $0.kind == .floor }
        XCTAssertFalse(floors.isEmpty)
        return try floors.flatMap { floor in
            let corners = floor.corners
            if corners.count == 3 { return [FloorTriangle(corners)] }
            let indices = Polygon.triangulate(corners)
            _ = try XCTUnwrap(!indices.isEmpty && indices.count.isMultiple(of: 3) ? true : nil)
            return stride(from: 0, to: indices.count, by: 3).map { offset in
                FloorTriangle((0..<3).map { corners[indices[offset + $0]] })
            }
        }
    }

    private func assertSafeRoute(_ route: Route, start: SIMD2<Float>, destination: AccessPoint,
                                 preference: RoutePreference, grid: OccupancyGrid,
                                 visibleFloor: [FloorTriangle], measuredFloor: [FloorTriangle],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let description = "\(preference.title) route to \(destination.title) from \(start)"
        XCTAssertEqual(route.destination.id, destination.id, description, file: file, line: line)
        XCTAssertEqual(route.preference, preference, description, file: file, line: line)
        XCTAssertEqual(route.unmappedLength, 0, accuracy: 0.0001, description, file: file, line: line)
        XCTAssertGreaterThanOrEqual(route.clearance, preference == .stepFree ? 0.45 : 0.3,
                                   description, file: file, line: line)
        XCTAssertGreaterThan(route.length, 0, description, file: file, line: line)
        XCTAssertLessThanOrEqual(simd_distance(try XCTUnwrap(route.waypoints.first), start), 1.5,
                                 "\(description) starts too far from the selected place", file: file, line: line)
        XCTAssertLessThanOrEqual(simd_distance(try XCTUnwrap(route.waypoints.last), destination.floorPoint), 1.5,
                                 "\(description) stops before reaching the selected place", file: file, line: line)
        // The measured balcony edge in the same canonical map coordinates.
        // Source principalUV runs from (-21.15, -7.25) to (19.42, -7.25).
        let balconyA = SIMD2<Float>(37.198100, -2.201427)
        let balconyB = SIMD2<Float>(-2.801309, 4.578849)

        for (a, b) in zip(route.waypoints, route.waypoints.dropFirst()) {
            let count = max(1, Int(ceil(simd_distance(a, b) / 0.01)))
            for i in 0...count {
                let point = a + (b - a) * (Float(i) / Float(count))
                guard visibleFloor.contains(where: { $0.contains(point) }) else {
                    XCTFail("\(description) leaves actual USDZ floor at \(point)", file: file, line: line)
                    return
                }
                guard measuredFloor.contains(where: { $0.contains(point) }) else {
                    XCTFail("\(description) leaves navigation coverage at \(point)", file: file, line: line)
                    return
                }
                guard distance(point, to: balconyA, balconyB) >= 0.45 else {
                    XCTFail("\(description) approaches the exposed balcony edge at \(point)", file: file, line: line)
                    return
                }
                let cell = try XCTUnwrap(grid.index(containing: point), description, file: file, line: line)
                guard !grid.isBlocked(cell), !grid.isUnmapped(cell) else {
                    XCTFail("\(description) crosses a blocked or unmapped cell at \(point)", file: file, line: line)
                    return
                }
            }
        }
    }

    func testLoungeRoutesToEveryRegisteredFloor2PlaceStayOnTheBundledFloor() throws {
        let map = try load("student-center-east-floor-2-navigation")
        XCTAssertTrue(StudentCenterCatalog.isDisplayable(map))
        let visibleFloor = try floorTriangles(map: map).map(FloorTriangle.init)
        let measuredFloor = try navigationTriangles(map: map)
        let landmarks = try registeredLandmarks(map: map)
        XCTAssertEqual(Set(landmarks.map(\.title)),
                       Set(["Lounge", "Balcony", "Lifts", "Gallery", "Restroom passage", "Seating", "West seating"]))
        let lounge = try XCTUnwrap(landmarks.first { $0.title == "Lounge" })
        let planner = RoutePlanner(map: map)
        let elevators = map.points.filter { $0.kind == .elevator }
        XCTAssertEqual(elevators.count, 2)
        let destinations = landmarks.filter { $0.id != lounge.id } + elevators

        for preference in [RoutePreference.stepFree, .fastest] {
            for destination in destinations {
                for (start, goal) in [(lounge, destination), (destination, lounge)] {
                    let route = try XCTUnwrap(planner.route(from: start.floorPoint, to: goal,
                        conditions: preference.navigationConditions(map: map)),
                        "\(preference.title): \(start.title) → \(goal.title) must remain available")
                    let grid = try XCTUnwrap(planner.grids.first { $0.clearance == route.clearance })
                    try assertSafeRoute(route, start: start.floorPoint, destination: goal,
                                        preference: preference, grid: grid,
                                        visibleFloor: visibleFloor, measuredFloor: measuredFloor)
                }
            }
        }

        // Retain the original balcony-corner regression, independently of the lounge label.
        let cornerStart = SIMD2<Float>(12.827781, -7.452379)
        for elevator in elevators {
            let route = try XCTUnwrap(planner.route(from: cornerStart, to: elevator,
                conditions: RoutePreference.stepFree.navigationConditions(map: map)))
            let grid = try XCTUnwrap(planner.grids.first { $0.clearance == route.clearance })
            try assertSafeRoute(route, start: cornerStart, destination: elevator,
                                preference: .stepFree, grid: grid,
                                visibleFloor: visibleFloor, measuredFloor: measuredFloor)
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
        XCTAssertEqual(navigation.points.filter { $0.kind == .elevator }.count, 2)
        XCTAssertEqual(navigation.floorY, original.floorY)
        _ = try XCTUnwrap(original.footprints.count > 65 ? true : nil)
        let measuredLoungeObstacles = Array(original.footprints[54...65])
        XCTAssertEqual(measuredLoungeObstacles.count, 12)
        for obstacle in measuredLoungeObstacles {
            XCTAssertEqual(obstacle.kind, .obstacle)
            XCTAssertEqual(navigation.footprints.filter { $0 == obstacle }.count, 1,
                           "Retain each original measured lounge obstacle exactly once")
        }
        XCTAssertEqual(navigation.requiresMeasuredFloorCoverage, true)
    }
}
