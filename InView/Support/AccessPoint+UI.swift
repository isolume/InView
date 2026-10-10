import AccessCore
import SwiftUI

extension VisionDetection.Kind {
    var title: String {
        switch self {
        case .elevator: "Elevator"
        case .ramp: "Ramp"
        case .stairs: "Stairs"
        }
    }

    var symbolName: String {
        accessPointKind?.symbolName ?? "figure.stairs"
    }

    var tint: Color {
        accessPointKind?.tint ?? Theme.stairs
    }
}

extension AccessPoint.Kind {
    var symbolName: String {
        switch self {
        // Bare glyphs: badges and tags supply the colored container.
        case .elevator: "arrow.up.arrow.down"
        case .ramp: "figure.roll"
        case .destination: "flag.fill"
        }
    }

    var tint: Color {
        switch self {
        case .elevator: Theme.accent
        case .ramp: Theme.ramp
        case .destination: Theme.accent
        }
    }

    /// `tint` for RealityKit materials.
    var uiTint: UIColor {
        switch self {
        case .elevator: Theme.accentUIColor
        case .ramp: Theme.rampUIColor
        case .destination: Theme.accentUIColor
        }
    }
}
