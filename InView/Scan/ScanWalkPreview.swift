import AccessCore
import simd
import SwiftUI

/// A review of captured coverage, not a navigation route. Tracking gaps stay disconnected.
struct ScanWalkPreview: View {
    let map: VenueMap
    let trace: ScanWalkTrace
    let coverage: ScanWalkFloorCoverage.Assessment?
    var isLive = false

    var body: some View {
        Canvas { context, size in
            let footprints = Array(map.footprints.prefix(4_096)).filter {
                $0.corners.count <= 128 && $0.corners.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            }
            let positions = footprints.flatMap(\.corners)
                + trace.samples.map { SIMD2($0.cameraPosition.x, $0.cameraPosition.z) }
            guard let first = positions.first else { return }
            let lower = positions.reduce(first, simd_min)
            let upper = positions.reduce(first, simd_max)
            let span = simd_max(upper - lower, SIMD2(repeating: 1))
            let scale = min((size.width - 32) / CGFloat(span.x), (size.height - 48) / CGFloat(span.y))
            let middle = (lower + upper) / 2
            func point(_ position: SIMD2<Float>) -> CGPoint {
                CGPoint(x: size.width / 2 + CGFloat(position.x - middle.x) * scale,
                        y: (size.height - 20) / 2 + CGFloat(position.y - middle.y) * scale)
            }
            func line(_ positions: [SIMD3<Float>]) -> Path {
                Path { $0.addLines(positions.map { point(SIMD2($0.x, $0.z)) }) }
            }
            for footprint in footprints where footprint.kind == .floor || footprint.kind == .wall {
                let path = Path { path in
                    path.addLines(footprint.corners.map(point))
                    path.closeSubpath()
                }
                context.fill(path, with: .color(footprint.kind == .floor
                                               ? Color.secondary.opacity(0.1) : Color.secondary.opacity(0.45)))
                if footprint.kind == .floor {
                    context.stroke(path, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                }
            }
            for segment in trace.segments {
                context.stroke(line(segment.map(\.cameraPosition)), with: .color(Theme.route),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            for segment in coverage?.missingSegments ?? [] {
                if segment.count == 1, let position = segment.first {
                    let center = point(SIMD2(position.x, position.z))
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                                   with: .color(.orange), lineWidth: 2)
                } else {
                    // The white underlay and dashes distinguish missing coverage without color alone.
                    context.stroke(line(segment), with: .color(Color(.secondarySystemGroupedBackground)), lineWidth: 5)
                    context.stroke(line(segment), with: .color(.orange),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 4]))
                }
            }
            if let start = trace.samples.first {
                let center = point(SIMD2(start.cameraPosition.x, start.cameraPosition.z))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                             with: .color(Theme.route))
            }
            if let end = trace.samples.last {
                let center = point(SIMD2(end.cameraPosition.x, end.cameraPosition.z))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(.mint))
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(.primary), lineWidth: 1)
            }
            let caption = coverage?.hasMissingCoverage == true ? "Dashed: floor missing"
                : isLive ? String(format: "%.1f m recorded · local map", trace.distanceMeters) : "Recorded walk"
            context.draw(Text(caption).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height - 12))
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive ? "Live floor trace" : "Recorded walk")
        .accessibilityValue(accessibilityDescription)
        .overlay(alignment: .topTrailing) {
            if coverage?.isLimited == true || trace.isTruncated {
                Text("Partial coverage check").font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        }
    }

    private var accessibilityDescription: String {
        var description = coverage?.message ?? "Recorded camera positions shown over the floor map."
        if coverage?.isLimited == true || trace.isTruncated { description += " Coverage check is partial." }
        return description + " This is not a verified route."
    }
}

/// Shared by the map review and the Simulator fixture so the visible checks stay in sync.
struct ScanReviewSections: View {
    let map: VenueMap
    let trace: ScanWalkTrace?
    let coverage: ScanWalkFloorCoverage.Assessment?

    var body: some View {
        let checks = ScanReviewChecks(map: map)
        if checks.needsReview || coverage?.hasMissingCoverage == true {
            Section("Scan checks") {
                ForEach(checks.items) { check in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.title).font(.subheadline.weight(.medium))
                        Text(check.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if coverage?.hasMissingCoverage == true {
                    Label("Part of your recorded walk is missing from the floor map.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                }
            }
        }
        if let trace, !trace.samples.isEmpty {
            Section {
                ScanWalkPreview(map: map, trace: trace, coverage: coverage)
                    .frame(height: 210)
            } header: {
                Text("Recorded walk")
            } footer: {
                Text("The line shows where you carried the phone. Dashed sections need more floor coverage; they do not establish a usable route.")
            }
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// A missing corridor between two measured rooms. Never starts a camera or saves a map.
struct ScanReviewPreview: View {
    private let map = VenueMap(floorY: 0, footprints: [
        Footprint(floor: [[-2, -2], [2, -2], [2, 2], [-2, 2]], bottom: 0),
        Footprint(floor: [[5, -2], [9, -2], [9, 2], [5, 2]], bottom: 0),
    ], points: [], requiresMeasuredFloorCoverage: true)
    private let trace = try! ScanWalkTrace(samples: [
        .init(cameraPosition: [0, 1.3, 1], timestampSeconds: 0, startsSegment: true),
        .init(cameraPosition: [0, 1.3, 0], timestampSeconds: 1, startsSegment: false),
        .init(cameraPosition: [7, 1.3, 0], timestampSeconds: 8, startsSegment: false),
        .init(cameraPosition: [7, 1.3, -1], timestampSeconds: 9, startsSegment: false),
    ])

    var body: some View {
        NavigationStack {
            List {
                ScanReviewSections(map: map, trace: trace,
                                   coverage: ScanWalkFloorCoverage.assess(trace: trace, map: map))
                Section {
                    ReportSummaryCard(map: map, report: AccessibilityReport(map: map))
                }
            }
            .navigationTitle("Check scan")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
#endif
