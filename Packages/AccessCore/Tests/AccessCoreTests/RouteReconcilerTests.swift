import Foundation
import simd
import Testing
@testable import AccessCore

/// `demo-room.routes.json` is the server's answer for the app's example building (scan
/// `demo-room`, processed by the worker), from Reception (-1.825, 0.275) to the meeting room (-1.4, -11).
private func serverPlan() throws -> ServerRoutePlan {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/demo-room.routes.json")
    return try JSONDecoder().decode(ServerRoutePlan.self, from: Data(contentsOf: url))
}

struct RouteReconcilerTests {
    @Test func decodesTheServerPlan() throws {
        let plan = try serverPlan()
        #expect(plan.levelID(forFloorY: 0) == "L0")
        #expect(plan.origin.snappedDistance > 1.5, "the graph starts ~1.8 m from Reception")
        let fastest = try #require(plan.routes.first)
        #expect(fastest.labels == ["fastest"])
        #expect(fastest.accessibility.status == "not_accessible")
        #expect(fastest.features.contains { $0.type == "narrow_passage" && $0.accessible == false })
        #expect(fastest.legs.first?.polyline.count ?? 0 >= 2)
        #expect(plan.unreachable.contains { $0.profile == "accessible" })
    }

    @Test func deviceRedrawsTheLegShorterAndFindsTheWiderPathTheGraphMissed() throws {
        let plan = try serverPlan()
        let (map, start, _) = try RoutePlannerBenchmarkTests.demoRoom()
        let planner = RoutePlanner(map: map)
        let fastest = try #require(plan.routes.first)
        let reconciled = RouteReconciler.reconcile(fastest, planner: planner, floorLevelID: "L0", start: start)
        let leg = try #require(reconciled.legs.first)
        // Server: 16.9 m along the graph plus ~1.8 m to reach it. Device: ~15 m from Reception itself.
        #expect(abs(leg.serverDistance - (fastest.legs[0].distance + plan.origin.snappedDistance)) < 0.2)
        guard case .shorterOnDevice(let saved) = leg.check else {
            Issue.record("expected a shorter device path, got \(leg.check)"); return
        }
        #expect(saved > 2)
        #expect(leg.waypoints.first == leg.deviceRoute?.waypoints.first)
        #expect(simd_distance(leg.waypoints.first!, start) < 0.2, "drawn from where the person stands")
        #expect((leg.onMeasuredFloor ?? 0) > 0.6, "the server path lies mostly on measured free floor")
        #expect(reconciled.isConfirmed)
        // The server blocks this route for a 0.61 m squeeze between furniture; the device has a
        // 0.9 m-clear way around it. The verdict stays the server's; the flag invites review.
        #expect(reconciled.deviceFoundWiderPath)
        #expect(reconciled.route.accessibility.status == "not_accessible")
    }

    @Test func liveObstaclesThatCloseTheWayAreReportedAsBlocked() throws {
        let plan = try serverPlan()
        let (map, start, goal) = try RoutePlannerBenchmarkTests.demoRoom()
        let fastest = try #require(plan.routes.first)
        let end = try #require(fastest.legs.first?.polyline.last)
        // A ring of camera-seen obstacles around the leg's end.
        let ring = (0..<72).map { i -> SIMD2<Float> in
            let angle = Float(i) * .pi / 36
            return SIMD2(end.x, end.z) + 1.8 * SIMD2(cos(angle), sin(angle))
        }
        let reconciled = RouteReconciler.reconcile(fastest, planner: RoutePlanner(map: map), floorLevelID: "L0",
                                                   start: start, conditions: RouteConditions(obstacles: ring))
        #expect(reconciled.legs.first?.check == .blockedOnDevice)
        #expect(!reconciled.isConfirmed)
        #expect(!reconciled.deviceFoundWiderPath)
        #expect(goal.kind == .destination)
    }

    @Test func otherFloorsAndConnectorsAreLeftToTheServer() throws {
        let plan = try serverPlan()
        let (map, start, _) = try RoutePlannerBenchmarkTests.demoRoom()
        let fastest = try #require(plan.routes.first)
        let reconciled = RouteReconciler.reconcile(fastest, planner: RoutePlanner(map: map), floorLevelID: "L1", start: start)
        #expect(reconciled.legs.allSatisfy { $0.check == .notChecked && $0.deviceRoute == nil })
        #expect(abs(reconciled.distance - fastest.legs.reduce(0) { $0 + $1.distance }) < 0.01)
    }

    @Test func encodesRouteRequests() throws {
        let request = ServerRouteRequest(from: SIMD3(1, 0, 2), to: .place("mcd"))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect((object["from"] as? [String: Any])?["position_m"] as? [Double] == [1, 0, 2])
        #expect((object["to"] as? [String: Any])?["place_id"] as? String == "mcd")
        #expect(object["profiles"] as? [String] == ["fastest", "accessible"])
    }
}
