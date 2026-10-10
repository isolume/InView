import SwiftUI

@main
struct InViewApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--floor-picker-preview") {
                ScanFloorPickerPreview(isSwitch: false)
            } else if ProcessInfo.processInfo.arguments.contains("--floor-switch-preview") {
                ScanFloorPickerPreview(isSwitch: true)
            } else {
                MapScreen()
            }
            #else
            MapScreen()
            #endif
        }
    }
}
