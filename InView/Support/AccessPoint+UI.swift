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

extension SignReading.Category {
    var symbolName: String {
        switch self {
        case .room: "door.left.hand.closed"
        case .exit: "figure.walk.departure"
        case .restroom: "toilet.fill"
        case .elevator: AccessPoint.Kind.elevator.symbolName
        case .stairs: "figure.stairs"
        case .lobby: "sofa.fill"
        case .office: "person.text.rectangle.fill"
        case .other: "signpost.right.fill"
        }
    }

    var tint: Color {
        switch self {
        case .room: .indigo
        case .exit: .green
        case .restroom: .purple
        case .elevator: Theme.accent
        case .stairs: Theme.stairs
        case .lobby: .orange
        case .office: .brown
        case .other: .gray
        }
    }

    var uiTint: UIColor { UIColor(tint).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)) }
}

extension AccessPoint {
    /// Sign places show what the sign named: a door, an exit, a restroom.
    var symbolName: String { signCategory?.symbolName ?? kind.symbolName }
    var tint: Color { signCategory?.tint ?? kind.tint }
}
