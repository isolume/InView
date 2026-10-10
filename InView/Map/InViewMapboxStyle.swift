import MapboxMaps
import UIKit

/// One subdued palette for navigation and the native placement editor.
enum InViewMapboxStyle {
    static let outdoor = make(show3dObjects: true)
    static let placement = make(show3dObjects: false)

    private static func make(show3dObjects: Bool) -> MapStyle {
        MapStyle.standard(
            theme: .faded, lightPreset: .day,
            showPointOfInterestLabels: false, showTransitLabels: false,
            showPlaceLabels: true, showRoadLabels: true, showPedestrianRoads: true,
            show3dObjects: show3dObjects,
            colorBuildings: StyleColor(UIColor(red: 0.84, green: 0.84, blue: 0.81, alpha: 1)),
            colorCommercial: StyleColor(UIColor(red: 0.94, green: 0.93, blue: 0.88, alpha: 1)),
            colorEducation: StyleColor(UIColor(red: 0.94, green: 0.93, blue: 0.88, alpha: 1)),
            colorGreenspace: StyleColor(UIColor(red: 0.76, green: 0.85, blue: 0.68, alpha: 1)),
            colorIndustrial: StyleColor(UIColor(red: 0.91, green: 0.92, blue: 0.90, alpha: 1)),
            colorLand: StyleColor(UIColor(red: 0.94, green: 0.94, blue: 0.90, alpha: 1)),
            colorMedical: StyleColor(UIColor(red: 0.94, green: 0.93, blue: 0.88, alpha: 1)),
            colorMotorways: StyleColor(UIColor(red: 0.74, green: 0.78, blue: 0.79, alpha: 1)),
            colorPlaceLabels: StyleColor(UIColor.darkGray),
            colorRoadLabels: StyleColor(UIColor.darkGray),
            colorRoads: StyleColor(UIColor(red: 0.91, green: 0.92, blue: 0.91, alpha: 1)),
            colorTrunks: StyleColor(UIColor(red: 0.83, green: 0.86, blue: 0.86, alpha: 1)),
            colorWater: StyleColor(UIColor(red: 0.68, green: 0.83, blue: 0.89, alpha: 1)),
            show3dFacades: false, show3dLandmarks: false,
            showAdminBoundaries: false, showIndoor: false,
            showLandmarkIconLabels: false, showLandmarkIcons: false)
    }
}
