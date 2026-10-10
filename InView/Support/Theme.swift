import AccessCore
import SwiftUI

/// InView's design tokens: the one place colors, corner radii, type and symbols are chosen.
///
/// Liquid Glass is for controls that float over live content, the camera or a map. Content itself (Home's
/// cards, the report, lists) stays solid on grouped backgrounds. See `Components.swift` for the shared views.
enum Theme {
    // MARK: Color

    /// InView blue, the asset catalog's AccentColor with a lighter dark-mode version: routes, primary actions, elevators.
    static let accent = Color("AccentColor")
    /// Every route line, on every map and in AR.
    static let route = accent
    static let ramp = Color.teal
    static let stairs = Color.red
    /// Furniture and other objects on the maps.
    static let furniture = Color(red: 0.50, green: 0.53, blue: 0.54)

    /// The same colors for RealityKit, SceneKit and Mapbox, which take UIKit colors. Map screens are always
    /// light, so these are resolved for light mode.
    static let accentUIColor = light(UIColor(named: "AccentColor") ?? UIColor(red: 0.18, green: 0.38, blue: 0.96, alpha: 1))
    static let routeUIColor = accentUIColor
    static let rampUIColor = light(.systemTeal)
    static let stairsUIColor = light(.systemRed)

    private static func light(_ color: UIColor) -> UIColor {
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    }

    /// Barrier / warning / good, always shown with an icon and a word as well as the color.
    static func color(for severity: AccessibilityReport.Finding.Severity) -> Color {
        switch severity {
        case .barrier: .red
        case .warning: .orange
        case .good: .green
        }
    }

    /// `color(for:)` for RealityKit and SceneKit.
    static func uiColor(for severity: AccessibilityReport.Finding.Severity) -> UIColor {
        switch severity {
        case .barrier: light(.systemRed)
        case .warning: light(.systemOrange)
        case .good: light(.systemGreen)
        }
    }

    static func symbol(for severity: AccessibilityReport.Finding.Severity) -> String {
        switch severity {
        case .barrier: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .good: "checkmark.circle.fill"
        }
    }

    // MARK: Shape

    /// The only corner radii in the app. Inner radii are concentric with their container at about 12 pt padding.
    enum Radius {
        /// Floating glass panels over the camera or a map.
        static let panel: CGFloat = 28
        /// Solid content cards.
        static let card: CGFloat = 22
        /// Buttons, tiles and maps inside a panel or card.
        static let control: CGFloat = 16
        /// Photos and small badges.
        static let thumb: CGFloat = 10
    }

    // MARK: Symbols

    /// App-wide action glyphs: outline in toolbars, `.fill` inside colored badges. Access point kinds take theirs
    /// from `AccessPoint.Kind.symbolName`.
    enum Symbol {
        static let navigate = "arrow.triangle.turn.up.right.diamond.fill"
        static let scan = "viewfinder"
        static let demo = "play.fill"
        static let recenter = "scope"
        static let placeBuilding = "mappin.and.ellipse"
        static let photoreal = "sparkles"
        static let settings = "gearshape"
        static let door = "door.left.hand.open"
        static let furniture = "chair.lounge.fill"
        static let area = "square.dashed"
        static let needsStaff = "person.fill.questionmark"
        static let narrow = "arrow.left.and.right"

        /// The 2D / 3D toggle shows the view it switches to.
        static func dimension(switchingToTopDown: Bool) -> String { switchingToTopDown ? "view.2d" : "view.3d" }
    }
}

extension Font {
    /// Panel and sheet titles.
    static let panelTitle = Font.title2.bold()
    /// Numbers that matter: distances, scores, counts. SF Rounded is for numbers only; words stay in SF Pro.
    static let metric = Font.system(.title, design: .rounded).bold().monospacedDigit()
    static let metricSmall = Font.system(.headline, design: .rounded).monospacedDigit()
}

extension View {
    /// A grouped-style card: the standard container for content on solid backgrounds.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
