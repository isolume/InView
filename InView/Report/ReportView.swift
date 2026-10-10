import AccessCore
import simd
import SwiftUI

/// Numbers the report screen shows alongside the findings, read straight off the map.
struct ReportFacts {
    let doorWidths: [Float]
    let ramps: [AccessPoint]
    let elevators: [AccessPoint]
    let stairsCount: Int
    let furnitureCount: Int
    /// Rough floor area covered by the scan, from the walls' extent.
    let mappedArea: Float?

    init(map: VenueMap) {
        doorWidths = map.footprints.filter { $0.kind == .door }.map(\.size.x).sorted()
        ramps = map.points.filter { $0.kind == .ramp }
        elevators = map.points.filter { $0.kind == .elevator }
        stairsCount = map.footprints.filter { $0.kind == .stairs }.count
        furnitureCount = map.footprints.filter { $0.kind == .obstacle }.count
        let corners = map.footprints.filter { $0.kind == .wall }.flatMap(\.corners)
        if let first = corners.first {
            let (low, high) = corners.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
            mappedArea = (high.x - low.x) * (high.y - low.y)
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

    var verdict: String {
        switch score {
        case 90...: "Accessible"
        case 75..<90: "Mostly accessible"
        case 50..<75: "Partly accessible"
        default: "Hard to get around"
        }
    }

    var tally: String {
        let parts = [
            barriers.isEmpty ? nil : "\(barriers.count) barrier\(barriers.count == 1 ? "" : "s")",
            warnings.isEmpty ? nil : "\(warnings.count) to check",
            passes.isEmpty ? nil : "\(passes.count) passed",
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing to report yet" : parts.joined(separator: " · ")
    }
}

/// Circular score gauge with the letter grade in the middle.
struct ScoreRing: View {
    let report: AccessibilityReport
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle().stroke(Color(.tertiarySystemFill), lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: CGFloat(report.score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(report.grade).font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                Text("\(report.score)").font(.system(size: size * 0.17, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grade \(report.grade), \(report.score) out of 100")
    }

    private var color: Color {
        switch report.score {
        case 75...: .green
        case 50..<75: .orange
        default: .red
        }
    }
}

/// Score, verdict and the most important findings, linking to the full report.
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

/// The whole audit: score, measurements against the ADA limits, and every finding by severity.
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
                        StatTile(title: "Doors", value: "\(facts.doorWidths.count)", detail: facts.narrowDoors == 0 ? "All wide enough" : "\(facts.narrowDoors) too narrow", severity: facts.narrowDoors == 0 ? .good : .barrier, symbol: "door.left.hand.open")
                        StatTile(title: "Ramps", value: "\(facts.ramps.count)", detail: rampDetail(facts), severity: facts.ramps.contains(where: \.isTooSteep) ? .barrier : facts.ramps.isEmpty ? nil : .good, symbol: "figure.roll")
                        StatTile(title: "Elevators", value: "\(facts.elevators.count)", detail: elevatorDetail(facts), severity: facts.elevators.isEmpty ? .warning : facts.elevators.contains(where: \.requiresAssistance) ? .warning : .good, symbol: "arrow.up.arrow.down.square")
                        StatTile(title: "Stairs", value: "\(facts.stairsCount)", detail: facts.stairsCount == 0 ? "None found" : "Routed around", severity: nil, symbol: "figure.stairs")
                        StatTile(title: "Furniture", value: "\(facts.furnitureCount)", detail: "Mapped as obstacles", severity: nil, symbol: "chair.lounge")
                        StatTile(title: "Area", value: facts.mappedArea.map { "≈\(Int($0.rounded())) m²" } ?? "–", detail: "Floor mapped", severity: nil, symbol: "square.dashed")
                    }
                }

                if !facts.doorWidths.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Door widths").sectionHeading()
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

                FindingGroup(title: "Barriers", findings: report.barriers)
                FindingGroup(title: "Worth checking", findings: report.warnings)
                FindingGroup(title: "Works well", findings: report.passes)

                Text("Checked against the 2010 ADA Standards: 81 cm (32 in) door clear width, 91 cm (36 in) passage width and a 1:12 maximum ramp slope (§§ 403–405). Measurements come from LiDAR and can be a few centimeters off, so confirm anything critical with a tape measure.")
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
        if facts.ramps.isEmpty { return "None found" }
        let steep = facts.ramps.filter(\.isTooSteep).count
        return steep == 0 ? "Within ADA slope" : "\(steep) too steep"
    }

    private func elevatorDetail(_ facts: ReportFacts) -> String {
        if facts.elevators.isEmpty { return "None found" }
        let staffed = facts.elevators.filter(\.requiresAssistance).count
        return staffed == 0 ? "Usable on your own" : "\(staffed) need staff"
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
            Text(value).font(.system(.title, design: .rounded).weight(.bold))
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

/// One bar per door against the 81 cm minimum.
private struct DoorWidthChart: View {
    let widths: [Float]
    /// Bars run from 0 to this width.
    private let scaleMaximum: Float = 1.2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                let passes = width >= OccupancyGrid.minimumDoorWidth
                HStack(spacing: 10) {
                    Text("Door \(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    GeometryReader { geometry in
                        let threshold = geometry.size.width * CGFloat(OccupancyGrid.minimumDoorWidth / scaleMaximum)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill)).frame(height: 8)
                            Capsule()
                                .fill(passes ? Color.green : Color.red)
                                .frame(width: geometry.size.width * CGFloat(min(width, scaleMaximum) / scaleMaximum), height: 8)
                            Rectangle().fill(.primary).frame(width: 2, height: 18).offset(x: threshold - 1)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 18)
                    HStack(spacing: 3) {
                        Image(systemName: passes ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(passes ? .green : .red)
                        Text("\(Int((width * 100).rounded())) cm").monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(width: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Door \(index + 1), \(Int((width * 100).rounded())) centimeters, \(passes ? "wide enough" : "too narrow")")
            }
            Text("Line marks the 81 cm minimum").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// A ramp's measured slope on a 0–10° track with the ADA 1:12 limit marked.
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
                    if let slope = ramp.slopeDegrees {
                        Capsule()
                            .fill(ramp.isTooSteep ? Color.red : Color.green)
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
                Text(String(format: "ADA limit %.1f° (1:12)", AccessPoint.maximumRampSlope))
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
        if let slope = ramp.slopeDegrees {
            let run = 1 / tan(slope * .pi / 180)
            HStack(spacing: 4) {
                Image(systemName: ramp.isTooSteep ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(ramp.isTooSteep ? .red : .green)
                Text(String(format: "%.1f° · 1:%.0f", slope, run)).monospacedDigit()
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
