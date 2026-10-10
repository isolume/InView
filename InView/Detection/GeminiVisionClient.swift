import AccessCore
import Foundation

/// Asks Gemini where elevators and ramps are in a camera frame. Gemini is trained to point at
/// things in images, which is what pin placement depends on.
struct GeminiVisionClient {
    struct Detection: Decodable {
        let kind: AccessPoint.Kind
        let name: String
        let confidence: Float
        /// The floor spot to navigate to, as Gemini's [y, x] normalized to 0...1000.
        let point: [Double]
        /// A spot in the middle of a ramp's surface, used to measure its slope. Same as `point` for elevators.
        let surfacePoint: [Double]

        /// Normalized (0...1, top-left origin) image positions.
        var target: CGPoint? { Self.normalized(point) }
        var surface: CGPoint? { Self.normalized(surfacePoint) }

        private static func normalized(_ yx: [Double]) -> CGPoint? {
            guard yx.count == 2 else { return nil }
            return CGPoint(x: yx[1] / 1000, y: yx[0] / 1000)
        }
    }

    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case blocked(String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): "Gemini \(status): \(message)"
            case .blocked(let reason): "Gemini blocked the request: \(reason)"
            case .noOutput: "Gemini returned no output"
            }
        }
    }

    private let apiKey: String
    private let model: String

    /// Nil when no API key is configured.
    init?() {
        guard let apiKey = AppConfig.geminiKey else { return nil }
        self.apiKey = apiKey
        model = AppConfig.geminiModel
    }

    func detect(jpeg: Data) async throws -> [Detection] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: jpeg))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.error.message
            throw ClientError.http(status: status, message: message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }

        let payload = try JSONDecoder().decode(ResponsePayload.self, from: data)
        guard let candidate = payload.candidates?.first else {
            throw ClientError.blocked(payload.promptFeedback?.blockReason ?? "no candidates")
        }
        if let reason = candidate.finishReason, reason != "STOP" {
            throw ClientError.blocked(reason)
        }
        let text = (candidate.content?.parts ?? []).filter { $0.thought != true }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw ClientError.noOutput }
        return try JSONDecoder().decode(DetectionList.self, from: Data(text.utf8)).detections
    }

    private func body(for jpeg: Data) -> [String: Any] {
        [
            "systemInstruction": ["parts": [["text": Self.instructions]]],
            "contents": [[
                "role": "user",
                "parts": [
                    ["inlineData": ["mimeType": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["text": "Find elevators and ramps in this photo."],
                ],
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": Self.schema,
                "thinkingConfig": ["thinkingLevel": "LOW"],
            ],
        ]
    }

    private static let instructions = """
    You help volunteers map buildings for wheelchair users. Each photo comes from a phone held upright \
    while walking through a building. Report only these features, and only when clearly visible:
    - elevator: elevator doors (usually metal, with a call-button panel beside them) or an elevator call panel.
    - ramp: a sloped walkway or sloped section of floor a wheelchair can roll along. Not stairs, not escalators.
    For each one:
    - point: [y, x] normalized to 0-1000, the spot on the floor where a wheelchair user should go: \
    in front of the elevator doors, or the bottom of the ramp.
    - surfacePoint: [y, x] normalized to 0-1000. For a ramp, a spot in the middle of the ramp's walking surface. \
    For an elevator, repeat point.
    - name: a short name a person would use, from what you can see, e.g. "Lobby elevator", "Elevator B", \
    "Entrance ramp". Use visible signs or numbers when there are any.
    - confidence: your certainty from 0 to 1.
    Return an empty list when neither is visible. Do not guess.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "required": ["detections"],
        "properties": [
            "detections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "required": ["kind", "name", "confidence", "point", "surfacePoint"],
                    "properties": [
                        "kind": ["type": "string", "enum": AccessPoint.Kind.allCases.map(\.rawValue)],
                        "name": ["type": "string"],
                        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                        "point": ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1000], "minItems": 2, "maxItems": 2],
                        "surfacePoint": ["type": "array", "items": ["type": "number", "minimum": 0, "maximum": 1000], "minItems": 2, "maxItems": 2],
                    ],
                ],
            ],
        ],
    ]
}

private struct DetectionList: Decodable {
    let detections: [GeminiVisionClient.Detection]
}

private struct ResponsePayload: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
            }

            let parts: [Part]?
        }

        let content: Content?
        let finishReason: String?
    }

    struct PromptFeedback: Decodable {
        let blockReason: String?
    }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

private struct ErrorPayload: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
