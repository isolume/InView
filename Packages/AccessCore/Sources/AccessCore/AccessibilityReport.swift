import Foundation
import simd

/// A quick accessibility audit of a scanned floor: what blocks wheelchairs and what works.
public struct AccessibilityReport: Codable, Sendable {
    public struct Finding: Codable, Hashable, Identifiable, Sendable {
        public enum Severity: String, Codable, Sendable {
            case barrier
            case warning
            case good
        }

        public var id: String { "\(severity.rawValue)|\(title)|\(detail)" }
        public let severity: Severity
        public let title: String
        public let detail: String
    }

    public static let barrierPenalty = 20
    public static let warningPenalty = 7

    /// 0–100, losing points for each barrier and warning.
    public let score: Int
    public let findings: [Finding]

    public var grade: String {
        switch score {
        case 90...: "A"
        case 75..<90: "B"
        case 60..<75: "C"
        case 40..<60: "D"
        default: "F"
        }
    }

    public init(map: VenueMap, planner: RoutePlanner? = nil) {
        // This compatibility initializer has no cancellation source; compute only throws
        // when its explicitly supplied cancellation predicate becomes true.
        self = try! Self.compute(map: map, planner: planner, isCancelled: { false })
    }

    /// Background reviews can stop an obsolete audit without publishing a partial report.
    public static func make(map: VenueMap, planner: RoutePlanner? = nil) throws -> AccessibilityReport {
        try compute(map: map, planner: planner, isCancelled: { Task.isCancelled })
    }

    private init(score: Int, findings: [Finding]) {
        self.score = score
        self.findings = findings
    }

    private static func compute(map: VenueMap, planner: RoutePlanner?,
                                isCancelled: () -> Bool) throws -> AccessibilityReport {
        guard !isCancelled() else { throw CancellationError() }
        var findings: [Finding] = []

        let doors = map.footprints.filter { $0.kind == .door }
        let narrowDoors = doors.filter { $0.size.x < OccupancyGrid.minimumDoorWidth }
        if !narrowDoors.isEmpty {
            let widths = narrowDoors.map { "\(Int(($0.size.x * 100).rounded())) cm" }.joined(separator: ", ")
            findings.append(Finding(
                severity: .barrier,
                title: narrowDoors.count == 1 ? "1 door is too narrow" : "\(narrowDoors.count) doors are too narrow",
                detail: "Measured \(widths). Wheelchairs need at least 81 cm (32 in) of clear width."
            ))
        } else if !doors.isEmpty {
            findings.append(Finding(severity: .good, title: "Doors are wide enough", detail: "All \(doors.count) doors give at least 81 cm (32 in) of clear width."))
        }

        let maximum = String(format: "%.1f°", AccessPoint.maximumRampSlope)
        for ramp in map.points where ramp.kind == .ramp {
            guard let slope = ramp.slopeDegrees else {
                findings.append(Finding(severity: .warning, title: "\(ramp.name): slope not measured", detail: "Rescan the ramp surface to check it against the ADA limit."))
                continue
            }
            let measured = String(format: "%.1f°", slope)
            findings.append(ramp.isTooSteep
                ? Finding(severity: .barrier, title: "\(ramp.name) is too steep", detail: "Measured \(measured); the ADA allows at most \(maximum) (1:12).")
                : Finding(severity: .good, title: "\(ramp.name) is a gentle slope", detail: "Measured \(measured), within the ADA limit of \(maximum)."))
        }

        let stairs = map.footprints.filter { $0.kind == .stairs }
        let stepFree = map.points.filter { $0.kind == .elevator || ($0.kind == .ramp && !$0.isTooSteep) }
        if !stairs.isEmpty {
            findings.append(stepFree.isEmpty
                ? Finding(severity: .barrier, title: "Stairs with no step-free alternative", detail: "No elevator or usable ramp was found on this floor.")
                : Finding(severity: .good, title: "Stairs have a step-free alternative", detail: stepFree.map(\.name).joined(separator: ", ") + "."))
        }
        if !map.points.contains(where: { $0.kind == .elevator }) {
            findings.append(Finding(severity: .warning, title: "No elevator mapped", detail: "Other floors may be unreachable by wheelchair."))
        }

        for point in map.points where point.requiresAssistance {
            findings.append(Finding(severity: .warning, title: "\(point.name) needs staff to operate", detail: "Wheelchair users can't use it on their own. InView can text building staff to arrange help."))
        }

        // Every access point should be reachable step-free from where the scan began (usually the entrance).
        let clearances: [Float?]
        if map.points.isEmpty {
            // A scan with no destinations has no reachability questions; avoid building three floor grids.
            clearances = []
        } else {
            guard !isCancelled() else { throw CancellationError() }
            let planner = planner ?? RoutePlanner(map: map)
            clearances = try planner.reachableClearances(from: .zero, to: map.points, isCancelled: isCancelled)
        }
        for (point, clearance) in zip(map.points, clearances) {
            guard !isCancelled() else { throw CancellationError() }
            guard let clearance else {
                findings.append(Finding(severity: .barrier, title: "\(point.name) can't be reached", detail: "No step-free path from the entrance with enough room for a wheelchair."))
                continue
            }
            if clearance < RoutePlanner.clearances[0] {
                findings.append(Finding(severity: .warning, title: "Tight squeeze to \(point.name)", detail: "The way there has passages narrower than 90 cm (36 in)."))
            }
        }

        let barriers = findings.filter { $0.severity == .barrier }.count
        let warnings = findings.filter { $0.severity == .warning }.count
        guard !isCancelled() else { throw CancellationError() }
        return AccessibilityReport(score: max(0, 100 - barriers * Self.barrierPenalty - warnings * Self.warningPenalty),
                                   findings: findings.sorted { $0.severity.rank < $1.severity.rank })
    }
}

extension AccessibilityReport.Finding.Severity {
    fileprivate var rank: Int {
        switch self {
        case .barrier: 0
        case .warning: 1
        case .good: 2
        }
    }
}
