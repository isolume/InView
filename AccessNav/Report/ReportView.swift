import AccessCore
import SwiftUI

/// The score badge plus each finding, worst first.
struct ReportView: View {
    let report: AccessibilityReport
    /// Show only the score and the first few findings.
    var limit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ScoreBadge(report: report)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility score").font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(limit.map { Array(report.findings.prefix($0)) } ?? report.findings) { finding in
                FindingRow(finding: finding)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        let barriers = report.findings.filter { $0.severity == .barrier }.count
        let warnings = report.findings.filter { $0.severity == .warning }.count
        if barriers == 0 && warnings == 0 { return "No barriers found" }
        return [
            barriers > 0 ? "\(barriers) barrier\(barriers == 1 ? "" : "s")" : nil,
            warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

struct ScoreBadge: View {
    let report: AccessibilityReport

    var body: some View {
        VStack(spacing: 0) {
            Text(report.grade).font(.title.bold())
            Text("\(report.score)").font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.white)
        .frame(width: 56, height: 56)
        .background(color.gradient, in: Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grade \(report.grade), score \(report.score) out of 100")
    }

    private var color: Color {
        switch report.score {
        case 75...: .green
        case 50..<75: .orange
        default: .red
        }
    }
}

private struct FindingRow: View {
    let finding: AccessibilityReport.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.subheadline.weight(.semibold))
                Text(finding.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch finding.severity {
        case .barrier: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .good: "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch finding.severity {
        case .barrier: .red
        case .warning: .orange
        case .good: .green
        }
    }
}
