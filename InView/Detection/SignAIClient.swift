import AccessCore
import Foundation

/// Asks an OpenAI vision model what a sign labels, from a close crop of it. On-device OCR does the
/// reading at camera rate; this checks it, fixes misreads ("2O4"), and reads pictogram-only signs
/// (a running figure, restroom icons) that have no text for OCR.
struct SignAIClient {
    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): "OpenAI \(status): \(message)"
            case .noOutput: "The model returned no answer."
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let reasoningEffort: String?

    /// Nil when no API key is configured; the reader then relies on OCR alone.
    init?() {
        guard let apiKey = AppConfig.openAIKey else { return nil }
        self.apiKey = apiKey
        model = AppConfig.openAIModel
        reasoningEffort = AppConfig.openAIReasoningEffort.map { _ in "low" }
    }

    /// What the sign in the photo labels, or nil when it isn't a door, room or exit sign.
    /// - Parameter ocrText: What the phone read, as a hint the model may correct.
    func read(jpeg: Data, ocrText: String?) async throws -> SignReading? {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(jpeg: jpeg, ocrText: ocrText))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let text = payload.output.flatMap({ $0.content ?? [] }).first(where: { $0.type == "output_text" })?.text else {
            throw ClientError.noOutput
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        guard answer.isSign, answer.confidence >= 0.5,
              let category = SignReading.Category(rawValue: answer.category) else { return nil }
        let title = answer.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 60 else { return nil }
        let detail = answer.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = answer.roomNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return SignReading(category: category, title: title,
                           detail: detail.isEmpty || detail.count > 60 ? nil : detail,
                           roomNumber: number.isEmpty ? nil : number)
    }

    private func body(jpeg: Data, ocrText: String?) -> [String: Any] {
        let hint = ocrText.map { "On-device OCR read: \"\($0)\". It may contain mistakes." } ?? "On-device OCR read no text."
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": Self.instructions,
            "input": [[
                "role": "user",
                "content": [
                    ["type": "input_text", "text": hint],
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())", "detail": "high"],
                ],
            ]],
            "text": ["format": ["type": "json_schema", "name": "sign_reading", "strict": true, "schema": Self.schema]],
        ]
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }
        return body
    }

    private static let instructions = """
    You read building signage for an indoor wheelchair-navigation map. The photo is a close crop of \
    one sign on a wall or above a door. Say what place the sign labels.
    - category: room (numbered room or suite plate), exit (EXIT or emergency-exit sign, including the \
    green running-figure pictogram), restroom, elevator, stairs, lobby, office (a named room such as a \
    lab, lounge or office without a number), or other.
    - title: a short name to read aloud, e.g. "Room 204", "Exit", "Women's restroom", "Main lobby".
    - detail: a secondary name on the same plate, like "Chemistry Lab", else "".
    - room_number: the room number exactly as printed, else "".
    - is_sign false for posters, notices, screens, or anything that is not a place sign.
    - Correct obvious OCR misreads (O for 0, l for 1). Never invent a number you cannot see.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["is_sign", "category", "title", "detail", "room_number", "confidence"],
        "properties": [
            "is_sign": ["type": "boolean"],
            "category": ["type": "string", "enum": SignReading.Category.allCases.map(\.rawValue)],
            "title": ["type": "string"],
            "detail": ["type": "string"],
            "room_number": ["type": "string"],
            "confidence": ["type": "number"],
        ],
    ]

    private struct Answer: Decodable {
        let isSign: Bool
        let category: String
        let title: String
        let detail: String
        let roomNumber: String
        let confidence: Float

        enum CodingKeys: String, CodingKey {
            case isSign = "is_sign", category, title, detail, roomNumber = "room_number", confidence
        }
    }

    private struct Payload: Decodable {
        struct Item: Decodable { let content: [Part]? }
        struct Part: Decodable { let type: String; let text: String? }
        let output: [Item]
    }
}
