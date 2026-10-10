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
        case .elevator: "arrow.up.arrow.down.square.fill"
        case .ramp: "figure.roll"
        case .destination: "flag.fill"
        }
    }

    var tint: Color {
        switch self {
        case .elevator: Theme.accent
        case .ramp: .teal
        case .destination: Theme.accent
        }
    }

    /// `tint` for RealityKit materials.
    var uiTint: UIColor {
        switch self {
        case .elevator: Theme.accentUIColor
        case .ramp: .systemTeal
        case .destination: Theme.accentUIColor
        }
    }
}
