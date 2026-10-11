import Foundation
import simd
import Testing
@testable import AccessCore

/// Timings for the on-device planner on the bundled, measured Student Center floor. Printed so a
/// run documents current performance; the bounds only catch order-of-magnitude regressions.
@Suite(.serialized)
struct RoutePlannerBenchmarkTests {
    private func studentCenter() throws -> VenueMap {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("InView/Resources/StudentCenter/student-center-east-floor-2.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VenueMap.self, from: Data(contentsOf: url))
    }

    private func seconds(_ body: () -> Void, repeats: Int = 5) -> Double {
        var best = Double.infinity
        for _ in 0..<repeats {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        return best
    }

    @Test func studentCenterFloorTimings() throws {
        let map = try studentCenter()
        let elevator = try #require(map.points.first { $0.kind == .elevator })
        var planner: RoutePlanner!
        let build = seconds({ planner = RoutePlanner(map: map) }, repeats: 3)
        let grid = planner.grids[0]
        // The free, reachable cell farthest from the elevator: the longest route on this floor.
        let reach = grid.search(from: try #require(grid.nearestFreeIndex(to: elevator.floorPoint, within: 2)))
        let far = try #require((0..<reach.cost.count).filter { reach.cost[$0].isFinite }
            .max { simd_distance(grid.center(of: $0), elevator.floorPoint) < simd_distance(grid.center(of: $1), elevator.floorPoint) })
        let start = grid.center(of: far)

        var route: Route?
        let stepFree = seconds { route = planner.route(from: start, to: elevator) }
        let found = try #require(route)
        var fastestRoute: Route?
        let fastest = seconds { fastestRoute = planner.route(from: start, to: elevator,
                                                             conditions: RouteConditions(preference: .fastest)) }
        let reroute = seconds { _ = planner.reroute(found, from: start + SIMD2(0.5, 0)) }
        let obstacles = seconds {
            _ = planner.route(from: start, to: elevator, conditions: RouteConditions(obstacles: [found.waypoints[found.waypoints.count / 2]]))
        }
        let cells = planner.grids.map { $0.width * $0.height }
        print("""
        BENCH local grid planner · Student Center floor 2
          grid \(grid.width)×\(grid.height) cells @ \(grid.cellSize) m (\(cells.reduce(0, +)) cells over \(cells.count) clearances)
          build planner (3 grids)   \(String(format: "%.1f", build * 1000)) ms
          step-free route           \(String(format: "%.1f", stepFree * 1000)) ms · \(String(format: "%.1f", found.length)) m, \(found.waypoints.count) waypoints, clearance \(found.clearance) m
          fastest route             \(String(format: "%.1f", fastest * 1000)) ms · \(String(format: "%.1f", fastestRoute?.length ?? .nan)) m
          reroute (A*)              \(String(format: "%.1f", reroute * 1000)) ms
          route around 1 obstacle   \(String(format: "%.1f", obstacles * 1000)) ms
        """)
        #expect(found.length > 10)
        #expect(stepFree < 5)
    }

    /// The app's example building, built the way `NavigationDemo.load` builds it. The server
    /// processes this same capture as scan `demo-room`, so the two planners can be compared.
    static func demoRoom() throws -> (VenueMap, start: SIMD2<Float>, goal: AccessPoint) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = try JSONDecoder().decode(CaptureBundle.self, from: Data(contentsOf:
            root.appendingPathComponent("InView/Resources/demo-room-capture.json")))
        func matrix(_ v: [Float]) -> simd_float4x4 {
            simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                    SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
        }
        let floors = capture.surfaces.filter { $0.kind == "floor" }.map { $0.mapFromSurface[13] }.sorted()
        let floorY = floors.isEmpty ? Float(0) : floors[floors.count / 2]
        var footprints: [Footprint] = []
        for surface in capture.surfaces {
            let kind: Footprint.Kind
            switch surface.kind {
            case "wall": kind = .wall
            case "door": kind = .door
            case "opening": kind = .opening
            default: continue
            }
            footprints.append(Footprint(kind: kind, transform: matrix(surface.mapFromSurface),
                                        width: surface.dimensionsM[0], depth: 0.15))
        }
        for object in capture.objects {
            guard object.category != "rug",
                  object.mapFromObject[13] - object.dimensionsM[1] / 2 < floorY + 0.7 else { continue }
            footprints.append(Footprint(kind: object.category == "stairs" ? .stairs : .obstacle,
                                        transform: matrix(object.mapFromObject),
                                        width: object.dimensionsM[0], depth: object.dimensionsM[2]))
        }
        let goal = AccessPoint(kind: .destination, name: "Meeting room", position: SIMD3(-1.4, floorY, -11),
                               source: .manual, confidence: 1)
        let map = VenueMap(createdAt: Date(timeIntervalSince1970: 0), floorY: floorY, footprints: footprints, points: [goal])
        return (map, SIMD2(-1.825, 0.275), goal)
    }

    @Test func demoRoomRouteForServerComparison() throws {
        let (map, start, goal) = try Self.demoRoom()
        var planner: RoutePlanner!
        let build = seconds({ planner = RoutePlanner(map: map) }, repeats: 3)
        var route: Route?
        let elapsed = seconds { route = planner.route(from: start, to: goal) }
        let found = try #require(route)
        let points = found.waypoints.map { String(format: "[%.2f,%.2f]", $0.x, $0.y) }.joined(separator: ",")
        print("BENCH local demo-room · build \(String(format: "%.1f", build * 1000)) ms · route \(String(format: "%.2f", elapsed * 1000)) ms · \(String(format: "%.2f", found.length)) m · clearance \(found.clearance) · waypoints [\(points)]")
        #expect(found.length > 10)
    }
}
