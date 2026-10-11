import Foundation
import simd

/// Measurement checks for a scanned floor. Findings describe captured evidence,
/// not a certification of the space or a guarantee that every barrier was found.
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

    /// A finding-based review status. A high legacy score cannot establish accessibility
    /// when the scan contains little or no measured evidence.
    public var summary: String {
        if findings.contains(where: { $0.severity == .barrier }) { return "Potential barriers found" }
        if findings.contains(where: { $0.severity == .warning }) { return "Measurements to review" }
        if findings.contains(where: { $0.severity == .good }) { return "No barriers found in measurements" }
        return "No measurements yet"
    }

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
        // Ramp checks below retain the name of each ramp; the other missing-evidence
        // checks also belong in saved reports, not just the live scan review.
        var findings = ScanReviewChecks(map: map).items.filter { $0.id != .rampSlopes }.map {
            Finding(severity: .warning, title: $0.title, detail: $0.detail)
        }

        for kind in [Footprint.Kind.door, .opening] {
            let measured = map.footprints.filter { $0.kind == kind && ScanReviewChecks.isMeasuredWidth($0.size.x) }
            let narrow = measured.filter { $0.size.x < OccupancyGrid.minimumDoorWidth }
            let noun = kind == .door ? "door" : "opening"
            if !narrow.isEmpty {
                let widths = narrow.map { String(format: "%.0f cm", $0.size.x * 100) }.joined(separator: ", ")
                findings.append(Finding(
                    severity: .barrier,
                    title: narrow.count == 1 ? "1 \(noun) is too narrow" : "\(narrow.count) \(noun)s are too narrow",
                    detail: "Estimated widths: \(widths), below the 81 cm guide. Confirm the usable clearance on site."
                ))
            } else if !measured.isEmpty {
                findings.append(Finding(severity: .good, title: "\(kind == .door ? "Door" : "Opening") widths meet the guide",
                                        detail: "\(measured.count) measured at 81 cm or wider. Confirm the usable clearance on site."))
            }
        }

        let maximum = String(format: "%.1f°", AccessPoint.maximumRampSlope)
        for ramp in map.points where ramp.kind == .ramp {
            guard ScanReviewChecks.isMeasuredSlope(ramp.slopeDegrees), let slope = ramp.slopeDegrees else {
                findings.append(Finding(severity: .warning, title: "\(ramp.name): slope not measured", detail: "Rescan the ramp surface before relying on its incline."))
                continue
            }
            let measured = String(format: "%.1f°", slope)
            findings.append(ramp.isTooSteep
                ? Finding(severity: .barrier, title: "\(ramp.name) is too steep", detail: "Estimated \(measured), above the \(maximum) (1:12) guide.")
                : Finding(severity: .good, title: "\(ramp.name) slope meets the guide", detail: "Estimated \(measured), within the \(maximum) guide. Surface condition and landings still need checking."))
        }

        let stairs = map.footprints.filter { $0.kind == .stairs }
        let stepFree = map.points.filter {
            $0.kind == .elevator || ($0.kind == .ramp && ScanReviewChecks.isMeasuredSlope($0.slopeDegrees) && !$0.isTooSteep)
        }
        if !stairs.isEmpty {
            findings.append(stepFree.isEmpty
                ? Finding(severity: .barrier, title: "Stairs with no step-free alternative", detail: "No elevator or usable ramp was found on this floor.")
                : Finding(severity: .warning, title: "Check the mapped stairs alternative", detail: stepFree.map(\.name).joined(separator: ", ") + ". Confirm it serves the same floors and is available."))
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
                findings.append(Finding(severity: .barrier, title: "\(point.name) can't be reached", detail: "No path was found from the scan's starting point. Check for missing floor coverage, blocked passages or insufficient clearance."))
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
