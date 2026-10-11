import AppIntents
import Foundation

/// "Hey Siri, take me to the nearest elevator in InView": opens the app and starts directions
/// to the closest elevator, from the person's live position where InView can find them.
struct NearestElevatorIntent: AppIntent {
    static let title: LocalizedStringResource = "Directions to the Nearest Elevator"
    static let description = IntentDescription("Opens InView and shows the way to the closest elevator.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        InViewIntents.requestNearestElevator()
        return .result()
    }
}

struct InViewShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NearestElevatorIntent(), phrases: [
            "Take me to the nearest elevator in \(.applicationName)",
            "Nearest elevator in \(.applicationName)",
            "Find an elevator with \(.applicationName)",
        ], shortTitle: "Nearest Elevator", systemImageName: "arrow.up.arrow.down")
    }
}

/// Hands a request from Siri or Shortcuts to the map, which may not exist yet on a cold launch.
@MainActor
enum InViewIntents {
    static let nearestElevator = Notification.Name("InView.nearestElevatorRequested")
    private static var isNearestElevatorPending = false

    static func requestNearestElevator() {
        isNearestElevatorPending = true
        NotificationCenter.default.post(name: nearestElevator, object: nil)
    }

    /// True once per request, for the map to act on when it appears or hears the notification.
    static func takeNearestElevatorRequest() -> Bool {
        defer { isNearestElevatorPending = false }
        return isNearestElevatorPending
    }
}
