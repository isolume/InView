import AccessCore
import Foundation
import simd

/// What the building map on the server says about a route the device planned, after checking the
/// server's path against this floor's measured grid. The device route stays the one drawn and
/// guided; this adds the server's floors-aware accessibility screening and features.
struct ServerRouteCheck: Equatable {
    var headline: String
    var details: [String]
    var symbol: String
    var isWarning: Bool

    /// Asks the server for the same trip and reconciles its answer. Returns nil when the server is
    /// unavailable or the scan has no navigation data, so offline routing is never held up.
    static func run(scanID: String, map: VenueMap, start: SIMD2<Float>, destination: AccessPoint,
                    placeID: String?, preference: RoutePreference) async -> ServerRouteCheck? {
        guard let baseURL = AppConfig.backendURL else { return nil }
        let client = BackendClient(baseURL: baseURL, accessToken: AppConfig.backendToken)
        let request = ServerRouteRequest(
            from: SIMD3(start.x, map.floorY, start.y),
            to: placeID.map { .place($0) } ?? .position(destination.position))
        let plan: ServerRoutePlan
        do {
            guard let found = try await client.routes(scanID: scanID, request: request) else { return nil }
            plan = found
        } catch let error as BackendClientError {
            if case .http(_, "no_route", _) = error {
                return ServerRouteCheck(headline: "The building map has no connected route here",
                                        details: ["This device’s route uses measured floor the building map doesn’t connect yet."],
                                        symbol: "questionmark.circle", isWarning: true)
            }
            return nil
        } catch { return nil }
        guard let levelID = plan.levelID(forFloorY: map.floorY) else { return nil }
        let wanted = preference == .stepFree ? "accessible" : "fastest"
        let chosen = plan.routes.first { $0.labels.contains(wanted) } ?? plan.routes.first
        guard let chosen else { return nil }
        let reconciled = await Task.detached(priority: .utility) {
            RouteReconciler.reconcile(chosen, planner: RoutePlanner(map: map), floorLevelID: levelID,
                                      start: start, conditions: preference.conditions())
        }.value
        return summarize(reconciled, plan: plan, preference: preference)
    }

    static func summarize(_ reconciled: ReconciledRoute, plan: ServerRoutePlan, preference: RoutePreference) -> ServerRouteCheck {
        let route = reconciled.route
        var details: [String] = []
        let noStepFree = preference == .stepFree && !route.labels.contains("accessible")
        let headline: String, symbol: String
        var warning = false
        switch (noStepFree, route.accessibility.status) {
        case (true, _):
            headline = "The building map found no step-free route"; symbol = "exclamationmark.triangle"; warning = true
        case (_, "accessible"):
            headline = "Building map: step-free route"; symbol = "checkmark.seal"
        case (_, "unverified"):
            headline = "Building map: step-free, some parts unverified"; symbol = "questionmark.circle"
        default:
            let reason = route.accessibility.blocking.first?.reason ?? "a barrier"
            headline = "Building map: not step-free (\(reason))"; symbol = "exclamationmark.triangle"; warning = true
        }
        if reconciled.deviceFoundWiderPath {
            details.append("This device found a way at least 0.9 m wide where the building map saw a narrow passage.")
        }
        for leg in reconciled.legs {
            switch leg.check {
            case .confirmed:
                details.append("Distance confirmed on this device (\(Int(leg.distance.rounded())) m).")
            case .shorterOnDevice(let meters):
                details.append("This device found a path \(Int(meters.rounded())) m shorter than the building map’s.")
            case .longerOnDevice(let meters):
                details.append("This device needs \(Int(meters.rounded())) m more to keep clear of obstacles.")
            case .blockedOnDevice:
                details.append("Something blocks the building map’s path here; the device route avoids it.")
                warning = true
            case .notChecked:
                continue
            }
        }
        let doors = route.features.filter { $0.type == "door" }.count
        let narrow = route.features.filter { $0.type == "narrow_passage" }.count
        let floors = route.levelChanges
        let parts = [doors > 0 ? "\(doors) door\(doors == 1 ? "" : "s")" : nil,
                     narrow > 0 ? "\(narrow) narrow passage\(narrow == 1 ? "" : "s")" : nil,
                     floors > 0 ? "\(floors) floor change\(floors == 1 ? "" : "s")" : nil].compactMap { $0 }
        if !parts.isEmpty { details.append("Passes " + parts.joined(separator: " · ") + ".") }
        if let unreachable = plan.unreachable.first(where: { $0.profile == wanted(preference) }), noStepFree {
            details.append(unreachable.reason)
        }
        return ServerRouteCheck(headline: headline, details: details, symbol: symbol, isWarning: warning)
    }

    private static func wanted(_ preference: RoutePreference) -> String {
        preference == .stepFree ? "accessible" : "fastest"
    }
}
