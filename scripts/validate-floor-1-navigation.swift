import AccessCore
import CryptoKit
import Foundation
import simd
import Darwin

setbuf(stdout, nil)

// Compile against the current AccessCore product. The optional --grid-only mode
// emits component diagnostics without running the route matrix.
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let gridOnly = CommandLine.arguments.contains("--grid-only")
let data = try Data(contentsOf: input)
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let map = try decoder.decode(ElevatedFloorMap.self, from: data)
try map.validate()
let planner = try ElevatedFloorRoutePlanner(map: map)
let profiles: [RoutePreference] = [.stepFree, .fastest]
var grids: [String: [Float: OccupancyGrid]] = [:]
var componentLabels: [String: [Float: [Int]]] = [:]
var componentRecords: [[String: Any]] = []
var gridRecords: [[String: Any]] = []
var samples: [(location: ElevatedFloorLocation, preference: RoutePreference, connected: Bool, component: Int, area: Double)] = []

for zone in map.zones {
    grids[zone.id] = [:]; componentLabels[zone.id] = [:]
    for clearance: Float in [0.45, 0.3] {
        let grid = OccupancyGrid(map: zone.map, clearance: clearance)
        grids[zone.id]![clearance] = grid
        var labels = [Int](repeating: -1, count: grid.width * grid.height)
        var components: [[Int]] = []
        for seed in labels.indices where labels[seed] == -1 && !grid.isBlocked(seed) {
            let label = components.count
            var queue = [seed]; labels[seed] = label
            var head = 0
            while head < queue.count {
                let index = queue[head]; head += 1
                let x = index % grid.width, y = index / grid.width
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < grid.width, ny < grid.height else { continue }
                    let next = ny * grid.width + nx
                    guard labels[next] == -1, !grid.isBlocked(next) else { continue }
                    labels[next] = label; queue.append(next)
                }
            }
            components.append(queue)
        }
        componentLabels[zone.id]![clearance] = labels
        let sorted = components.indices.sorted { components[$0].count > components[$1].count }
        let named: [[String: Any]] = zone.map.points.map { point in
            ["name": point.title, "position": [point.position.x, point.position.y, point.position.z],
             "component": grid.index(containing: point.floorPoint).map { labels[$0] } ?? -1]
        }
        let landings: [[String: Any]] = map.connectors.flatMap { connector in
            [connector.from, connector.to].filter { $0.zoneID == zone.id }.map { location in
                ["connector": connector.id, "position": [location.position.x, location.position.y, location.position.z],
                 "component": grid.index(containing: location.floorPoint).map { labels[$0] } ?? -1]
            }
        }
        let freeCount = components.reduce(0) { $0 + $1.count }
        let summary: [[String: Any]] = sorted.prefix(20).map { index in
            let p = grid.center(of: components[index][components[index].count / 2])
            return ["id": index, "area_m2": Double(components[index].count) * 0.01, "sample_xz": [p.x, p.y]]
        }
        componentRecords.append(["zone_id": zone.id, "clearance_m": clearance, "component_count": components.count,
            "free_area_m2": Double(freeCount) * 0.01,
            "largest_component_fraction": freeCount > 0 ? Double(sorted.first.map { components[$0].count } ?? 0) / Double(freeCount) : 0,
            "largest_components": summary, "destinations": named, "connector_landings": landings])
        gridRecords.append(["zone_id": zone.id, "clearance_m": clearance, "origin": [grid.origin.x, grid.origin.y],
            "cell_size": grid.cellSize, "width": grid.width, "height": grid.height, "components": labels])
        if let largest = sorted.first {
            for component in sorted where component == largest || components[component].count >= 100 {
                let cells = components[component]
                var picked = Set<String>()
                for index in component == largest ? cells : [cells[cells.count / 2]] {
                    let p = grid.center(of: index)
                    let key = "\(Int(floor(p.x / 8))):\(Int(floor(p.y / 8)))"
                    if picked.insert(key).inserted {
                        samples.append((.init(zoneID: zone.id, position: SIMD3(p.x, zone.map.floorY, p.y)),
                                        clearance == 0.45 ? .stepFree : .fastest, component == largest,
                                        component, Double(cells.count) * 0.01))
                    }
                }
            }
        }
        print("GRID", zone.id, clearance, "components", components.count, "largest", summary.first ?? [:])
    }
}

let places: [(String, ElevatedFloorLocation)] = map.zones.flatMap { zone in
    zone.map.points.map { ($0.title, .init(zoneID: zone.id, position: $0.position)) }
}
var routeRecords: [[String: Any]] = []
var checkedSamples = 0
var allPass = true
var allNamedPass = true
var surfaceSafetyPass = true
func inspect(_ from: ElevatedFloorLocation, _ to: ElevatedFloorLocation, name: String,
             profile: RoutePreference, unavailable: Set<String> = [], expected: Bool = true,
             componentEvidence: [String: Any]? = nil) {
    let route = planner.route(from: from, to: to, conditions: profile.conditions(),
                              destinationName: name, unavailableConnectors: unavailable)
    var record: [String: Any] = ["name": name, "preference": profile.rawValue,
        "from_zone": from.zoneID, "from": [from.position.x, from.position.y, from.position.z],
        "to_zone": to.zoneID, "to": [to.position.x, to.position.y, to.position.z],
        "expected_route": expected, "found_route": route != nil]
    if let componentEvidence { record["component_evidence"] = componentEvidence }
    var good = (route != nil) == expected
    if let route {
        var surfaces: [[String: Any]] = [], transitions: [String] = []
        var samplesChecked = 0, blocked = 0
        for segment in route.segments {
            switch segment {
            case .surface(let surface):
                let grid = grids[surface.zoneID]![surface.route.clearance]!
                for (a, b) in zip(surface.route.waypoints, surface.route.waypoints.dropFirst()) {
                    let a64 = SIMD2(Double(a.x), Double(a.y)), b64 = SIMD2(Double(b.x), Double(b.y))
                    let count = max(1, Int(ceil(simd_distance(a64, b64) / 0.01)))
                    for i in 0...count {
                        // Independent double-precision sampling avoids moving a point
                        // across a grid-corner tie through Float interpolation rounding.
                        let p = a64 + (b64 - a64) * Double(i) / Double(count)
                        let x = Int(floor((p.x - Double(grid.origin.x)) / Double(grid.cellSize)))
                        let y = Int(floor((p.y - Double(grid.origin.y)) / Double(grid.cellSize)))
                        samplesChecked += 1
                        if x < 0 || y < 0 || x >= grid.width || y >= grid.height || grid.isBlocked(y * grid.width + x) {
                            blocked += 1
                        }
                    }
                }
                surfaces.append(["zone_id": surface.zoneID, "clearance_m": surface.route.clearance,
                    "length_m": surface.route.length, "points_xz": surface.route.waypoints.map { [$0.x, $0.y] }])
            case .transition(let transition):
                transitions.append(transition.connectorID)
                if profile == .stepFree && transition.kind == .stairs { good = false }
            }
        }
        good = good && blocked == 0
        surfaceSafetyPass = surfaceSafetyPass && blocked == 0
        checkedSamples += samplesChecked
        record["checked_samples"] = samplesChecked; record["blocked_samples"] = blocked
        record["surfaces"] = surfaces; record["connectors"] = transitions
    }
    record["pass"] = good
    allPass = allPass && good
    routeRecords.append(record)
    if routeRecords.count % 25 == 0 { print("PROGRESS", routeRecords.count, "route cases") }
    if !good { print("FAILED", name, profile.rawValue, "route", route != nil) }
}

if !gridOnly {
    for profile in profiles {
        for a in places.indices {
            for b in places.indices where a != b {
                inspect(places[a].1, places[b].1, name: "\(places[a].0) to \(places[b].0)", profile: profile)
            }
        }
        allNamedPass = allNamedPass && allPass
        if let anchor = places.first(where: { $0.0 == "Information" }) {
            for (index, sample) in samples.enumerated() where sample.preference == profile {
                let evidence: [String: Any] = ["component": sample.component, "area_m2": sample.area,
                    "connected_to_main_network": sample.connected,
                    "policy": "Every component >=1m2 sampled; smaller raster fragments counted in full-grid coverage statistics"]
                inspect(anchor.1, sample.location, name: "Arbitrary map point \(index)", profile: profile,
                        expected: sample.connected, componentEvidence: evidence)
                inspect(sample.location, anchor.1, name: "Reverse arbitrary map point \(index)", profile: profile,
                        expected: sample.connected, componentEvidence: evidence)
            }
        }
    }
    if let lower = places.first(where: { $0.0 == "Information" }), let upper = places.first(where: { $0.0 == "Auditorium" }) {
        inspect(lower.1, upper.1, name: "Elevator unavailable", profile: .stepFree,
                unavailable: ["main-to-l-elevator"], expected: false)
        inspect(lower.1, upper.1, name: "Elevator unavailable using stairs", profile: .fastest,
                unavailable: ["main-to-l-elevator"])
    }
}
let result: [String: Any] = ["navigation_map_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
    "all_routes_pass": !gridOnly && allPass, "route_count": routeRecords.count, "checked_surface_samples": checkedSamples,
    "all_named_routes_pass": !gridOnly && allNamedPass, "surface_safety_pass": !gridOnly && surfaceSafetyPass,
    "all_sampled_points_reachable": samples.allSatisfy { $0.connected },
    "known_disconnected_component_samples": samples.filter { !$0.connected }.count,
    "sample_spacing_m": 0.01, "sample_arithmetic": "Double interpolation and grid-cell lookup from original Float waypoint coordinates",
    "components": componentRecords, "arbitrary_point_count": samples.count, "routes": routeRecords]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
try JSONSerialization.data(withJSONObject: gridRecords, options: [.sortedKeys]).write(to: output.deletingPathExtension().appendingPathExtension("grids.json"))
print("RESULT", "pass", !gridOnly && allPass, "routes", routeRecords.count, "surface_samples", checkedSamples)
