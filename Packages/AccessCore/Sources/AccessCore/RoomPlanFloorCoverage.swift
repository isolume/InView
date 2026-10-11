import Foundation
import simd

/// Adds confirmed observed floor only where RoomPlan did not supply coverage.
/// Missing native floors are valid: retain their measured substitutes without bridging gaps.
public enum RoomPlanFloorCoverage {
    public static func additions(observed: [Footprint], nativeFloors: [Footprint], floorY: Float) -> [Footprint] {
        var kept = nativeFloors.filter {
            $0.kind == .floor && $0.bottom != nil && abs($0.bottom! - floorY) < 0.2
        }
        let hasNativeFloor = !kept.isEmpty
        var additions: [Footprint] = []
        var pending = observed.filter { $0.kind == .floor }
        while !pending.isEmpty {
            let candidates = pending
            pending.removeAll(keepingCapacity: true)
            let previousCount = kept.count
            for footprint in candidates {
                guard let bottom = footprint.bottom, bottom.isFinite, abs(bottom - floorY) < 0.2,
                      footprint.center.x.isFinite, footprint.center.y.isFinite,
                      footprint.size.x.isFinite, footprint.size.y.isFinite,
                      footprint.size.x > 0, footprint.size.y > 0, footprint.yaw.isFinite,
                      footprint.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                // Never fall back to a rectangle or a convex hull if subtraction is unsupported.
                guard let regions = try? BuildingFootprintCutaway.subtractRegions(
                    mapped: kept.map(\.corners), from: footprint.corners
                ) else { continue }
                if hasNativeFloor {
                    let measuredArea = abs(Polygon.signedArea(footprint.corners))
                    let uncoveredArea = regions.reduce(Float.zero) { total, region in
                        total + abs(Polygon.signedArea(region.exterior))
                            - region.holes.reduce(Float.zero) { $0 + abs(Polygon.signedArea($1)) }
                    }
                    // When native coverage exists, a separate raw patch isn't proof of another
                    // completed room. Without native floors, retain every confirmed measured
                    // region at this height instead of arbitrarily keeping only the first anchor.
                    guard measuredArea - uncoveredArea >= 0.01 else {
                        // A later measurement may connect this exact patch to the native floor.
                        // Anchor ordering must not decide how much of a corridor survives.
                        pending.append(footprint)
                        continue
                    }
                }
                for region in regions {
                    // Footprint stores one exterior ring. Split regions with holes into exact
                    // pieces so a measured gap cannot accidentally become navigable coverage.
                    let polygons: [[SIMD2<Float>]]
                    if region.holes.isEmpty {
                        polygons = [region.exterior]
                    } else {
                        guard let pieces = try? BuildingFootprintCutaway.subtract(
                            mapped: [], from: region.exterior, holes: region.holes
                        ) else { continue }
                        polygons = pieces
                    }
                    for polygon in polygons {
                        let addition = Footprint(floor: polygon, bottom: bottom)
                        additions.append(addition)
                        kept.append(addition)
                    }
                }
            }
            // Every further pass must add measured coverage and consume a candidate.
            // Disconnected patches stop here; never bridge them or retry indefinitely.
            if kept.count == previousCount { break }
        }
        return additions
    }
}
