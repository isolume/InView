import SwiftUI

/// Both map appearances use the same navigation controls and route.
enum MapPresentation: String, CaseIterable, Identifiable {
    case indoor
    case mapbox

    var id: String { rawValue }
    var title: String {
        switch self {
        case .indoor: "Indoor only"
        case .mapbox: "Surroundings"
        }
    }
}
