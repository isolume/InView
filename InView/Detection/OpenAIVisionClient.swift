import Foundation

/// Asks an OpenAI vision model where elevators, ramps and stairs are in a camera frame.
struct OpenAIVisionClient: VisionDetector {
    private struct Detection: Decodable {
        let kind: VisionDetection.Kind
        let name: String
        let confidence: Float
        let x: Double
        let y: Double
        let surfaceX: Double
        let surfaceY: Double

        private enum CodingKeys: String, CodingKey {
            case kind, name, confidence, x, y
            case surfaceX = "surface_x"
            case surfaceY = "surface_y"
        }
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

    func detect(jpeg: Data) async throws -> [VisionDetection] {
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
                    return try JSONDecoder().decode(DetectionList.self, from: Data(text.utf8)).detections.map {
                        VisionDetection(
                            kind: $0.kind,
                            name: $0.name,
                            confidence: $0.confidence,
                            target: CGPoint(x: $0.x, y: $0.y),
                            surface: CGPoint(x: $0.surfaceX, y: $0.surfaceY)
                        )
                    }
                }
            }
        }
        throw ClientError.noOutput
    }

    private func body(for jpeg: Data) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": VisionPrompt.instructions(coordinates: Self.coordinates),
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": VisionPrompt.userText],
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "auto"],
                ],
            ]],
            "text": ["format": [
                "type": "json_schema",
                "name": "accessibility_features",
                "strict": true,
                "schema": Self.schema,
            ]],
        ]
        if let reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort]
        }
        return body
    }

    private static let coordinates = """
    Give x, y for the point and surface_x, surface_y for the surface point, each normalized to the image: \
    0 is the left or top edge, 1 the right or bottom edge.
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
                    "required": ["kind", "name", "confidence", "x", "y", "surface_x", "surface_y"],
                    "properties": [
                        "kind": ["type": "string", "enum": VisionDetection.Kind.allCases.map(\.rawValue)],
                        "name": ["type": "string"],
                        "confidence": ["type": "number"],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "surface_x": ["type": "number"],
                        "surface_y": ["type": "number"],
                    ],
                ],
            ],
        ],
    ]

    private struct DetectionList: Decodable {
        let detections: [Detection]
    }
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
