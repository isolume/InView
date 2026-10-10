import AccessCore
import SwiftUI

extension AccessPoint.Kind {
    var symbolName: String {
        switch self {
        case .elevator: "arrow.up.arrow.down.square.fill"
        case .ramp: "figure.roll"
        case .destination: "mappin"
        }
    }

    var tint: Color {
        switch self {
        case .elevator: .blue
        case .ramp: .teal
        case .destination: .blue
        }
    }
}
