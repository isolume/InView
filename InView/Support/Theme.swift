import AccessCore
import SwiftUI

/// The app's few shared visual choices.
enum Theme {
    /// InView blue: routes, primary actions, elevators.
    static let accent = Color(red: 0.18, green: 0.38, blue: 0.96)
    static let stairs = Color.red
    static let cornerRadius: CGFloat = 22

    /// Barrier / warning / good, always shown with an icon and a word as well as the color.
    static func color(for severity: AccessibilityReport.Finding.Severity) -> Color {
        switch severity {
        case .barrier: .red
        case .warning: .orange
        case .good: .green
        }
    }

    static func symbol(for severity: AccessibilityReport.Finding.Severity) -> String {
        switch severity {
        case .barrier: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .good: "checkmark.circle.fill"
        }
    }
}

extension View {
    /// A grouped-style card: the standard container on every screen.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// Small uppercase heading above a card.
    func sectionHeading() -> some View {
        self
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }
}
