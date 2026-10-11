import Foundation
import simd

/// How to choose between mapped routes. Both modes respect observed floor,
/// closures and obstacles; stairs need an explicit building connection.
public enum RoutePreference: String, Codable, CaseIterable, Sendable {
    case stepFree = "step_free"
    case fastest

    public var title: String {
        switch self {
        case .stepFree: "Step-free"
        case .fastest: "Fastest"
        }
    }

    public var detail: String {
        switch self {
        case .stepFree: "Avoid stairs and keep wider clearance."
        case .fastest: "Stairs allowed when they save time."
        }
    }

    /// Use the same estimate in both modes; preference does not establish travel speed.
    public var walkingSpeedMetersPerSecond: Double { 1.0 }

    /// Navigation requirements. The lower-level RouteConditions initializer keeps
    /// its legacy defaults for measurement audits that inspect narrower passages.
    public func conditions(obstacles: [SIMD2<Float>] = []) -> RouteConditions {
        RouteConditions(obstacles: obstacles, minimumClearance: self == .stepFree ? 0.45 : 0.3,
                        requiresMeasuredRampSlope: true, preference: self)
    }
}
