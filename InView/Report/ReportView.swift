import AccessCore
import simd
import SwiftUI

/// Numbers the report screen shows alongside the findings, read straight off the map.
struct ReportFacts {
    let doorWidths: [Float]
    let doorwayCount: Int
    let checks: ScanReviewChecks
    let ramps: [AccessPoint]
    let elevators: [AccessPoint]
    let stairsCount: Int
    let furnitureCount: Int
    /// The bounding area of the measured walls, not measured floor coverage.
    let mappedArea: Float?

    init(map: VenueMap) {
        let doorways = map.footprints.filter { $0.kind == .door || $0.kind == .opening }
        doorWidths = doorways.map(\.size.x).filter(ScanReviewChecks.isMeasuredWidth).sorted()
        doorwayCount = doorways.count
        checks = ScanReviewChecks(map: map)
        ramps = map.points.filter { $0.kind == .ramp }
        elevators = map.points.filter { $0.kind == .elevator }
        stairsCount = map.footprints.filter { $0.kind == .stairs }.count
        furnitureCount = map.footprints.filter { $0.kind == .obstacle }.count
        let corners = map.footprints.filter { $0.kind == .wall }.flatMap(\.corners)
            .filter { $0.x.isFinite && $0.y.isFinite }
        if let first = corners.first {
            let (low, high) = corners.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
            let area = (high.x - low.x) * (high.y - low.y)
            mappedArea = area.isFinite ? area : nil
        } else {
            mappedArea = nil
        }
    }

    var narrowDoors: Int { doorWidths.filter { $0 < OccupancyGrid.minimumDoorWidth }.count }
}

extension AccessibilityReport {
    var barriers: [Finding] { findings.filter { $0.severity == .barrier } }
    var warnings: [Finding] { findings.filter { $0.severity == .warning } }
    var passes: [Finding] { findings.filter { $0.severity == .good } }

    var verdict: String { summary }

    var tally: String {
        let parts = [
            barriers.isEmpty ? nil : "\(barriers.count) barrier\(barriers.count == 1 ? "" : "s")",
            warnings.isEmpty ? nil : "\(warnings.count) to check",
            passes.isEmpty ? nil : "\(passes.count) measured check\(passes.count == 1 ? "" : "s")",
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing to report yet" : parts.joined(separator: " · ")
    }
}

/// Finding-based status badge. The stored score is retained for older reports,
/// but a scan grade would suggest more certainty than these measurements provide.
struct ScoreRing: View {
    let report: AccessibilityReport
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.12))
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(report.summary)
    }

    private var color: Color {
        if !report.barriers.isEmpty { return Theme.color(for: .barrier) }
        if !report.warnings.isEmpty { return Theme.color(for: .warning) }
        return report.passes.isEmpty ? .secondary : Theme.color(for: .good)
    }

    private var symbol: String {
        if !report.barriers.isEmpty { return "exclamationmark.triangle" }
        if !report.warnings.isEmpty { return "magnifyingglass" }
        return report.passes.isEmpty ? "questionmark" : "checkmark"
    }
}

/// Review status and the most important findings, linking to the full report.
struct ReportSummaryCard: View {
    let map: VenueMap
    let report: AccessibilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ScoreRing(report: report)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.verdict).font(.headline)
                    Text(report.tally).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ForEach(report.findings.prefix(3)) { FindingRow(finding: $0) }
            NavigationLink {
                FullReportView(map: map, report: report)
            } label: {
                HStack {
                    Text("Full report").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
        }
        .card()
    }
}

/// Captured measurements, missing evidence, and potential barriers.
struct FullReportView: View {
    let map: VenueMap
    let report: AccessibilityReport

    var body: some View {
        let facts = ReportFacts(map: map)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                VStack(alignment: .leading, spacing: 8) {
                    Text("At a glance").sectionHeading()
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        StatTile(title: "Doorways", value: "\(facts.doorwayCount)", detail: doorwayDetail(facts), severity: doorwaySeverity(facts), symbol: Theme.Symbol.door)
                        StatTile(title: "Ramps", value: "\(facts.ramps.count)", detail: rampDetail(facts), severity: rampSeverity(facts), symbol: AccessPoint.Kind.ramp.symbolName)
                        StatTile(title: "Elevators", value: "\(facts.elevators.count)", detail: elevatorDetail(facts), severity: facts.elevators.isEmpty ? .warning : facts.elevators.contains(where: \.requiresAssistance) ? .warning : .good, symbol: AccessPoint.Kind.elevator.symbolName)
                        StatTile(title: "Stairs", value: "\(facts.stairsCount)", detail: facts.stairsCount == 0 ? "None captured" : "Avoided in routing", severity: nil, symbol: VisionDetection.Kind.stairs.symbolName)
                        StatTile(title: "Furniture", value: "\(facts.furnitureCount)", detail: "Mapped as obstacles", severity: nil, symbol: Theme.Symbol.furniture)
                        StatTile(title: "Wall extent", value: facts.mappedArea.map { String(format: "≈%.0f m²", $0) } ?? "–", detail: "Bounds of captured walls", severity: nil, symbol: Theme.Symbol.area)
                    }
                }

                if !facts.doorWidths.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Estimated doorway widths").sectionHeading()
                        DoorWidthChart(widths: facts.doorWidths).card()
                    }
                }

                if !facts.ramps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ramp slopes").sectionHeading()
                        VStack(spacing: 16) {
                            ForEach(facts.ramps) { SlopeGauge(ramp: $0) }
                        }
                        .card()
                    }
                }

                FindingGroup(title: "Potential barriers", findings: report.barriers)
                FindingGroup(title: "Needs review", findings: report.warnings)
                FindingGroup(title: "Measured checks", findings: report.passes)

                Text("These checks use scan estimates and may miss barriers. Door swing, usable clearance, surface condition and access to other floors need an on-site check. Confirm critical measurements before relying on a route.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Accessibility report")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 18) {
            ScoreRing(report: report, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.verdict).font(.title2.bold())
                Text(report.tally).font(.subheadline).foregroundStyle(.secondary)
                Text("Scanned \(map.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .card(padding: 20)
    }

    private func rampDetail(_ facts: ReportFacts) -> String {
        if facts.ramps.isEmpty { return "None captured" }
        let steep = facts.ramps.filter { ScanReviewChecks.isMeasuredSlope($0.slopeDegrees) && $0.isTooSteep }.count
        if steep > 0 { return "\(steep) appear steep" }
        if facts.checks.unmeasuredRampCount > 0 { return "\(facts.checks.unmeasuredRampCount) not measured" }
        return "Slopes recorded"
    }

    private func rampSeverity(_ facts: ReportFacts) -> AccessibilityReport.Finding.Severity? {
        if facts.ramps.contains(where: { ScanReviewChecks.isMeasuredSlope($0.slopeDegrees) && $0.isTooSteep }) { return .barrier }
        if facts.checks.unmeasuredRampCount > 0 { return .warning }
        return facts.ramps.isEmpty ? nil : .good
    }

    private func doorwayDetail(_ facts: ReportFacts) -> String {
        if facts.doorWidths.isEmpty { return "Not measured" }
        if facts.narrowDoors > 0 { return "\(facts.narrowDoors) appear narrow" }
        if facts.checks.unmeasuredDoorwayCount > 0 { return "\(facts.checks.unmeasuredDoorwayCount) not measured" }
        return "Widths recorded"
    }

    private func doorwaySeverity(_ facts: ReportFacts) -> AccessibilityReport.Finding.Severity {
        if facts.narrowDoors > 0 { return .barrier }
        return facts.doorWidths.isEmpty || facts.checks.unmeasuredDoorwayCount > 0 ? .warning : .good
    }

    private func elevatorDetail(_ facts: ReportFacts) -> String {
        if facts.elevators.isEmpty { return "None captured" }
        let staffed = facts.elevators.filter(\.requiresAssistance).count
        return staffed == 0 ? "No staff need marked" : "\(staffed) need staff"
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let severity: AccessibilityReport.Finding.Severity?
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value).font(.metric)
            HStack(spacing: 4) {
                if let severity {
                    Image(systemName: Theme.symbol(for: severity)).foregroundStyle(Theme.color(for: severity))
                }
                Text(detail).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

/// One bar per measured door or opening against the 81 cm routing guide.
private struct DoorWidthChart: View {
    let widths: [Float]
    /// Bars run from 0 to this width.
    private let scaleMaximum: Float = 1.2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                let passes = width >= OccupancyGrid.minimumDoorWidth
                HStack(spacing: 10) {
                    Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                    GeometryReader { geometry in
                        let threshold = geometry.size.width * CGFloat(OccupancyGrid.minimumDoorWidth / scaleMaximum)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill)).frame(height: 8)
                            Capsule()
                                .fill(Theme.color(for: passes ? .good : .barrier))
                                .frame(width: geometry.size.width * CGFloat(min(width, scaleMaximum) / scaleMaximum), height: 8)
                            Rectangle().fill(.primary).frame(width: 2, height: 18).offset(x: threshold - 1)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                    HStack(spacing: 3) {
                        Image(systemName: Theme.symbol(for: passes ? .good : .barrier))
                            .foregroundStyle(Theme.color(for: passes ? .good : .barrier))
                        Text(String(format: "%.0f cm", width * 100)).monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(width: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Doorway \(index + 1), estimated \(String(format: "%.0f", width * 100)) centimeters, \(passes ? "meets width guide" : "below width guide")")
            }
            Text("Line marks the 81 cm width guide").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A ramp's estimated slope on a 0–10° track with the 1:12 routing guide marked.
private struct SlopeGauge: View {
    let ramp: AccessPoint
    private let scaleMaximum: Float = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ramp.name).font(.subheadline.weight(.semibold))
                Spacer()
                status
            }
            GeometryReader { geometry in
                let limit = geometry.size.width * CGFloat(AccessPoint.maximumRampSlope / scaleMaximum)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(height: 8)
                    if ScanReviewChecks.isMeasuredSlope(ramp.slopeDegrees), let slope = ramp.slopeDegrees {
                        Capsule()
                            .fill(Theme.color(for: ramp.isTooSteep ? .barrier : .good))
                            .frame(width: max(8, geometry.size.width * CGFloat(min(slope, scaleMaximum) / scaleMaximum)), height: 8)
                    }
                    Rectangle().fill(.primary).frame(width: 2, height: 18).offset(x: limit - 1)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            HStack {
                Text("0°")
                Spacer()
                Text(String(format: "Guide %.1f° (1:12)", AccessPoint.maximumRampSlope))
                Spacer()
                Text("10°")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        if ScanReviewChecks.isMeasuredSlope(ramp.slopeDegrees), let slope = ramp.slopeDegrees {
            let run = 1 / tan(slope * .pi / 180)
            HStack(spacing: 4) {
                Image(systemName: Theme.symbol(for: ramp.isTooSteep ? .barrier : .good))
                    .foregroundStyle(Theme.color(for: ramp.isTooSteep ? .barrier : .good))
                Text(slope == 0 ? "0° · level" : String(format: "%.1f° · 1:%.0f", slope, run)).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
        } else {
            Text("Not measured").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FindingGroup: View {
    let title: String
    let findings: [AccessibilityReport.Finding]

    var body: some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title) (\(findings.count))").sectionHeading()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(findings) { FindingRow(finding: $0) }
                }
                .card()
            }
        }
    }
}

struct FindingRow: View {
    let finding: AccessibilityReport.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Theme.symbol(for: finding.severity))
                .foregroundStyle(Theme.color(for: finding.severity))
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.subheadline.weight(.semibold))
                Text(finding.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
