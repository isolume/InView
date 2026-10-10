import Foundation
import os

/// Loggers for the device console. In Console.app, or with `log stream`, filter on the subsystem
/// (the bundle ID) and one of these categories.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "InView"
    /// Frames sent and analyzed, raycast hits and misses, LiDAR verdicts, and each sighting's tally.
    static let detection = Logger(subsystem: subsystem, category: "detection")
    /// RoomPlan sections, world map capture, saving.
    static let scan = Logger(subsystem: subsystem, category: "scan")
    /// Map loading, relocalization, routing.
    static let navigation = Logger(subsystem: subsystem, category: "navigation")
}
