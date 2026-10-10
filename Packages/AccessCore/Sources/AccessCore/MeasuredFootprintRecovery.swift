import simd

/// Overlap is not containment: a recovered corridor may overlap a room and extend well beyond it.
public enum MeasuredFootprintRecovery {
    public static func shouldKeep(_ candidate: Footprint, alongside kept: [Footprint]) -> Bool {
        let comparable = kept.filter { footprint in
            if candidate.kind == .obstacle {
                guard footprint.kind.blocksWheelchairs else { return false }
                if let first = candidate.bottom, let firstHeight = candidate.height,
                   let second = footprint.bottom, let secondHeight = footprint.height {
                    return first < second + secondHeight && second < first + firstHeight
                }
                return true
            }
            return footprint.kind == candidate.kind && abs((footprint.bottom ?? 0) - (candidate.bottom ?? 0)) < 0.3
        }
        guard !comparable.isEmpty else { return true }
        if candidate.kind == .floor {
            // Subtract measured coverage rather than its bounding rectangle. On a complexity
            // limit, keep the measurement; dropping it would silently truncate the scan.
            guard let remainder = try? BuildingFootprintCutaway.subtractRegions(
                mapped: comparable.map(\.corners), from: candidate.corners
            ) else { return true }
            return !remainder.isEmpty
        }
        // Thin surface fragments may cross or touch at a corner. Discard only when one
        // existing surface contains the entire candidate with a small fitting tolerance.
        return !comparable.contains { footprint in
            candidate.corners.allSatisfy { point in
                let local = footprint.local(point)
                return abs(local.x) <= footprint.size.x / 2 + 0.05
                    && abs(local.y) <= footprint.size.y / 2 + 0.05
            }
        }
    }
}
