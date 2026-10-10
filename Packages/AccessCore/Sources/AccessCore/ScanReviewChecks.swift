import Foundation
import simd

/// Missing measurements to revisit before finishing a scan. Passing these checks means
/// the measurements are present, not that the whole space is captured or accessible.
public struct ScanReviewChecks: Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public enum ID: String, Sendable {
            case floorCoverage, doorwayWidths, rampSlopes, destinations
        }

        public let id: ID
        public let title: String
        public let detail: String
    }

    public let items: [Item]
    public let doorwayMeasurementCount: Int
    public let unmeasuredDoorwayCount: Int
    public let unmeasuredRampCount: Int
    public let hasRoutingDestinations: Bool
    public var needsReview: Bool { !items.isEmpty }

    public init(map: VenueMap) {
        let doorways = map.footprints.filter { $0.kind == .door || $0.kind == .opening }
        doorwayMeasurementCount = doorways.filter { Self.isMeasuredWidth($0.size.x) }.count
        unmeasuredDoorwayCount = doorways.count - doorwayMeasurementCount
        unmeasuredRampCount = map.points.filter {
            $0.kind == .ramp && !Self.isMeasuredSlope($0.slopeDegrees)
        }.count
        hasRoutingDestinations = !map.points.isEmpty

        var items: [Item] = []
        // This is an absence check, not an estimate of floor coverage or routing validation.
        let hasFloorOutline = map.footprints.contains { footprint in
            guard footprint.kind == .floor, map.floorY.isFinite,
                  let bottom = footprint.bottom, bottom.isFinite,
                  abs(bottom - map.floorY) <= 0.35 else { return false }
            if footprint.polygon == nil {
                guard footprint.size.x.isFinite, footprint.size.y.isFinite,
                      footprint.size.x > 0, footprint.size.y > 0, footprint.yaw.isFinite else { return false }
            }
            let outline = footprint.corners
            guard (3...512).contains(outline.count),
                  outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            let area = Polygon.signedArea(outline)
            return area.isFinite && abs(area) > 1e-6
        }
        if !hasFloorOutline {
            items.append(Item(id: .floorCoverage, title: "Floor coverage not captured",
                              detail: "Scan the floor through rooms and doorways so routes can stay on measured ground."))
        }
        if doorwayMeasurementCount == 0 {
            items.append(Item(id: .doorwayWidths, title: "No doorway widths measured",
                              detail: "Capture doors and openings before relying on passage widths."))
        } else if unmeasuredDoorwayCount > 0 {
            items.append(Item(id: .doorwayWidths,
                              title: "\(unmeasuredDoorwayCount) doorway width\(unmeasuredDoorwayCount == 1 ? " needs" : "s need") another look",
                              detail: "Scan both sides of each opening to capture its width."))
        }
        if unmeasuredRampCount > 0 {
            items.append(Item(id: .rampSlopes,
                              title: "\(unmeasuredRampCount) ramp slope\(unmeasuredRampCount == 1 ? " needs" : "s need") measurement",
                              detail: "Scan the ramp surface. A ramp marker alone does not establish its incline."))
        }
        if !hasRoutingDestinations {
            items.append(Item(id: .destinations, title: "No destinations marked",
                              detail: "Name a room or mark an elevator or ramp to check routes from the scan's starting point."))
        }
        self.items = items
    }

    public static func isMeasuredWidth(_ width: Float) -> Bool {
        width.isFinite && width > 0
    }

    public static func isMeasuredSlope(_ slope: Float?) -> Bool {
        guard let slope else { return false }
        return slope.isFinite && slope >= 0 && slope < 90
    }
}
