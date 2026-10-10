import AccessCore
import Foundation

/// Asks an OpenAI vision model where elevators and ramps are in a camera frame.
struct OpenAIVisionClient {
    struct Detection: Decodable {
        let kind: AccessPoint.Kind
        let confidence: Float
        /// Normalized image position (0...1, top-left origin) of the floor spot to navigate to.
        let x: Double
        let y: Double
        let description: String
    }

    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case refusal(String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): "OpenAI \(status): \(message)"
            case .refusal(let message): "Model refused: \(message)"
            case .noOutput: "Model returned no output"
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let reasoningEffort: String?

    /// Nil when no API key is configured.
    init?() {
        guard let apiKey = AppConfig.openAIKey else { return nil }
        self.apiKey = apiKey
        model = AppConfig.openAIModel
        reasoningEffort = AppConfig.openAIReasoningEffort
    }

    func detect(jpeg: Data) async throws -> [Detection] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: jpeg))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorPayload.self, from: data))?.error.message
            throw ClientError.http(status: status, message: message ?? String(decoding: data.prefix(200), as: UTF8.self))
        }

        let payload = try JSONDecoder().decode(ResponsePayload.self, from: data)
        for item in payload.output where item.type == "message" {
            for part in item.content ?? [] {
                if let refusal = part.refusal { throw ClientError.refusal(refusal) }
                if part.type == "output_text", let text = part.text {
                    return try JSONDecoder().decode(DetectionList.self, from: Data(text.utf8)).detections
                }
            }
        }
        throw ClientError.noOutput
    }

    private func body(for jpeg: Data) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": Self.instructions,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "Find elevators and ramps in this photo."],
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "auto"],
                ],
            ]],
            "text": ["format": [
                "type": "json_schema",
                "name": "access_points",
                "strict": true,
                "schema": Self.schema,
            ]],
        ]
        if let reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort]
        }
        return body
    }

    private static let instructions = """
    You help volunteers map buildings for wheelchair users. Each photo comes from a phone held upright \
    while walking through a building. Report only these features, and only when clearly visible:
    - elevator: elevator doors (usually metal, with a call-button panel beside them) or an elevator call panel.
    - ramp: a sloped walkway or sloped section of floor a wheelchair can roll along. Not stairs, not escalators.
    For each one, x and y are the normalized image position (0 = left or top, 1 = right or bottom) of the spot \
    on the floor where a wheelchair user should go: in front of the elevator doors, or the bottom of the ramp.
    confidence is your certainty from 0 to 1. description is a few words, e.g. "steel elevator doors, left wall".
    Return an empty list when neither is visible. Do not guess.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["detections"],
        "properties": [
            "detections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["kind", "confidence", "x", "y", "description"],
                    "properties": [
                        "kind": ["type": "string", "enum": [AccessPoint.Kind.elevator, .ramp].map(\.rawValue)],
                        "confidence": ["type": "number"],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "description": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]
}

private struct DetectionList: Decodable {
    let detections: [OpenAIVisionClient.Detection]
}

private struct ResponsePayload: Decodable {
    struct Item: Decodable {
        let type: String
        let content: [Part]?
    }

    struct Part: Decodable {
        let type: String
        let text: String?
        let refusal: String?
    }

    let output: [Item]
}

private struct ErrorPayload: Decodable {
    struct Body: Decodable { let message: String }
    let error: Body
}
