import AccessCore
import Foundation

/// Something a vision model spotted in a camera frame.
struct VisionDetection {
    enum Kind: String, CaseIterable, Decodable {
        case elevator
        case ramp
        case stairs

        /// Elevators and ramps are destinations; stairs are barriers to route around.
        var accessPointKind: AccessPoint.Kind? {
            switch self {
            case .elevator: .elevator
            case .ramp: .ramp
            case .stairs: nil
            }
        }
    }

    let kind: Kind
    let name: String
    let confidence: Float
    /// Normalized position (0...1, top-left origin) in the portrait image: the floor spot to go to,
    /// or the front edge of the bottom step for stairs.
    let target: CGPoint
    /// A spot in the middle of a ramp's surface, for measuring its slope. Same as `target` otherwise.
    let surface: CGPoint
    /// Visible feature extent in the upright image; never an inferred hidden extent.
    var bounds: CGRect? = nil
    var elevatorEvidence: ElevatorEvidence? = nil

    enum ElevatorEvidence: String, Decodable {
        case doorAndPanel = "door_and_panel", doorway, panelOnly = "panel_only", signOnly = "sign_only"
        case notApplicable = "not_applicable"
    }

    var isValid: Bool {
        confidence.isFinite && (0...1).contains(confidence)
            && [target.x, target.y, surface.x, surface.y].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    static func visibleBounds(_ values: [Double]?) -> CGRect? {
        guard let v = values, v.count == 4, v.allSatisfy(\.isFinite),
              v[0] >= 0, v[1] >= 0, v[2] > 0, v[3] > 0,
              v[0] + v[2] <= 1.001, v[1] + v[3] <= 1.001 else { return nil }
        return CGRect(x: v[0], y: v[1], width: min(v[2], 1 - v[0]), height: min(v[3], 1 - v[1]))
    }
}

/// A model that finds elevators, ramps and stairs in a photo.
protocol VisionDetector: Sendable {
    func detect(jpeg: Data) async throws -> [VisionDetection]
}

enum VisionProvider: String {
    case openai
    case gemini

    /// The configured detector, or nil when its API key is missing.
    static func makeDetector() -> (any VisionDetector)? {
        switch AppConfig.visionProvider {
        case .openai: OpenAIVisionClient()
        case .gemini: GeminiVisionClient()
        }
    }
}

/// What to look for and where to point, shared by every provider. Each provider adds its own coordinate format.
enum VisionPrompt {
    static func instructions(coordinates: String) -> String {
        """
        You help volunteers map buildings for wheelchair users. Each photo comes from a phone held upright \
        while walking through a building. Report only these features, and only when clearly visible:
        - elevator: actual elevator doorways, open or closed. Look for door seams/frame plus call buttons, \
        floor indicators, or a visible cabin. Do not report ordinary metal doors, cabinets, standalone call panels, \
        or directional elevator signs as an entrance. Report each adjacent elevator doorway separately.
        - ramp: a sloped walkway or sloped section of floor a wheelchair can roll along. Not stairs, not escalators.
        - stairs: a staircase or steps where you can clearly see risers and treads, even a single step at a doorway. \
        Escalators count as stairs. Do not report floor tiles or patterns, shelves, bookcases, benches, bleacher seats, \
        ladders, or the edge of a platform unless actual steps are visible.
        For each one:
        - point: where a wheelchair user should go: on the floor in front of the elevator doors, or the bottom of \
        the ramp. For stairs, the middle of the bottom step's front edge.
        - surface point: for a ramp, a spot in the middle of its walking surface. Otherwise repeat point.
        - bounds: [x, y, width, height], ALWAYS normalized 0...1 in the upright image, enclosing only the visible \
        feature. For stairs include visible treads/risers, exclude railings, walls and landings. For elevators \
        include the doorway. Do not extrapolate behind occlusion. Stairways going down also count; point at the \
        nearest landing's step edge when the bottom of the flight is hidden.
        - elevator_evidence: door_and_panel if both doorway and call panel/indicator are visible, doorway if only \
        the doorway/cabin is clear, panel_only or sign_only for insufficient evidence, not_applicable for ramps/stairs.
        - name: a short name a person would use, from what you can see, e.g. "Lobby elevator", "Elevator B", \
        "Entrance ramp", "Main stairs". Use visible signs or numbers when there are any.
        - confidence: your certainty from 0 to 1. Only go above 0.8 for stairs when the steps are unmistakable.
        \(coordinates)
        Return an empty list when none are visible. Do not guess.
        """
    }

    static let userText = "Find elevators, ramps and stairs in this photo."
}
