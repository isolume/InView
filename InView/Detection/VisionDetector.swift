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
        - elevator: elevator doors (usually metal, with a call-button panel beside them) or an elevator call panel.
        - ramp: a sloped walkway or sloped section of floor a wheelchair can roll along. Not stairs, not escalators.
        - stairs: a staircase or steps where you can clearly see risers and treads, even a single step at a doorway. \
        Escalators count as stairs. Do not report floor tiles or patterns, shelves, bookcases, benches, bleacher seats, \
        ladders, or the edge of a platform unless actual steps are visible.
        For each one:
        - point: where a wheelchair user should go: on the floor in front of the elevator doors, or the bottom of \
        the ramp. For stairs, the middle of the bottom step's front edge.
        - surface point: for a ramp, a spot in the middle of its walking surface. Otherwise repeat point.
        - name: a short name a person would use, from what you can see, e.g. "Lobby elevator", "Elevator B", \
        "Entrance ramp", "Main stairs". Use visible signs or numbers when there are any.
        - confidence: your certainty from 0 to 1. Only go above 0.8 for stairs when the steps are unmistakable.
        \(coordinates)
        Return an empty list when none are visible. Do not guess.
        """
    }

    static let userText = "Find elevators, ramps and stairs in this photo."
}
