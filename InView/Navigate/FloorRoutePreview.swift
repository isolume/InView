import AccessCore
import Foundation
import simd

/// A floor opened for inspection, without moving the live navigation session.
struct FloorPreviewMap: Sendable {
    let level: Int
    let map: VenueMap?
    var elevatedMap: ElevatedFloorMap? = nil
    var scene: ProcessedScene? = nil
}

struct FloorPreviewLanding: Identifiable, Sendable {
    let id: String
    let title: String
    let kind: BuildingConnectorKind
    let point: AccessPoint
    var elevatedLocation: ElevatedFloorLocation? = nil
}

/// The arrival walk is planned only from a landing the person chooses. Connector
/// names and independent scan coordinates do not establish cross-floor service.
struct FloorArrivalPreview: Sendable {
    let destination: FloorNavigationDestination
    let floor: FloorPreviewMap
    var landings: [FloorPreviewLanding]
    var landing: FloorPreviewLanding? = nil
    var route: Route? = nil
    var elevatedRoute: ElevatedFloorRoute? = nil

    init(destination: FloorNavigationDestination, floor: FloorPreviewMap, preference: RoutePreference) {
        self.destination = destination
        self.floor = floor
        landings = Self.landings(in: floor, preference: preference)
    }

    static func landings(in floor: FloorPreviewMap, preference: RoutePreference) -> [FloorPreviewLanding] {
        if let map = floor.elevatedMap {
            return map.connectors.filter {
                $0.availability == .available && ($0.kind == .elevator || ($0.kind == .stairs && preference == .fastest))
            }.flatMap { connector in
                [("from", connector.from), ("to", connector.to)].map { side, location in
                    let zone = map.zones.first { $0.id == location.zoneID }
                    let name = connector.name ?? (connector.kind == .stairs ? "Stairs" : "Elevator")
                    let title = "\(name) · \(zone?.name ?? location.zoneID)"
                    return FloorPreviewLanding(id: "\(connector.id):\(side)", title: title,
                        kind: connector.kind == .stairs ? .stairs : .elevator,
                        point: AccessPoint(kind: connector.kind == .stairs ? .destination : .elevator,
                            name: title, position: location.position, source: .manual, confidence: 1),
                        elevatedLocation: location)
                }
            }
        } else {
            return floor.map.map { map in
                FloorTransferApproach.candidates(in: map, preference: preference).enumerated().map { index, approach in
                    FloorPreviewLanding(id: "\(approach.kind.rawValue):\(index)",
                        title: approach.kind == .stairs ? "Stairs \(index + 1)" : approach.destination.title,
                        kind: approach.kind, point: approach.destination)
                }
            } ?? []
        }
    }

    static func departureRoute(from start: ElevatedFloorLocation, to landing: FloorPreviewLanding,
                               in map: ElevatedFloorMap, preference: RoutePreference) -> ElevatedFloorRoute? {
        let floor = FloorPreviewMap(level: 0, map: nil, elevatedMap: map)
        guard let landing = landings(in: floor, preference: preference).first(where: { $0.id == landing.id }),
              let destination = landing.elevatedLocation,
              let planner = try? ElevatedFloorRoutePlanner(map: map) else { return nil }
        return planner.route(from: start, to: destination, conditions: preference.conditions(), destinationName: landing.title)
    }

    func selecting(_ landing: FloorPreviewLanding, preference: RoutePreference) -> Self {
        var result = self
        result.route = nil; result.elevatedRoute = nil
        guard let landing = landings.first(where: { $0.id == landing.id }) else { return result }
        result.landing = landing
        guard destination.level == floor.level, destination.isRoutable,
              preference != .stepFree || !landing.kind.involvesSteps else { return result }
        if let map = floor.elevatedMap {
            guard let start = landing.elevatedLocation,
                  let planner = try? ElevatedFloorRoutePlanner(map: map) else { return result }
            result.elevatedRoute = planner.route(from: start, to: destination.point.id,
                conditions: preference.conditions())
        } else if let map = floor.map {
            result.route = RoutePlanner(map: map).route(from: landing.point.floorPoint,
                to: destination.point, conditions: preference.navigationConditions(map: map))
        }
        return result
    }
}
