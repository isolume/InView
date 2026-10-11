import Foundation

/// Answers questions like "where is room 204?" with Gemini, grounded in the places the app knows.
/// Replies are written to be spoken aloud.
struct GeminiAssistantClient {
    struct Place {
        let id: UUID
        let name: String
        let kind: String
        let floor: Int
        /// Other places on the same floor, nearest first, so answers can say what something is near.
        let nearby: [String]
        /// Worth saying when it applies, like "needs a staff member to operate".
        let note: String?
        /// Straight-line meters from the person, when the camera has found them on this map.
        var distance: Float? = nil
    }

    struct Context {
        let buildingName: String
        let currentFloor: Int
        /// One line per floor: what map, if any, it has.
        let floorSummary: [String]
        let places: [Place]
    }

    struct Turn {
        let question: String
        let reply: String
    }

    struct Answer {
        let reply: String
        /// The listed place that answers the question, when there is exactly one.
        let placeID: UUID?
        /// The person wants to get to the place, not just hear about it.
        var wantsDirections = false
        /// "The nearest elevator": any place of that kind will do, so the closest by route is chosen.
        var wantsNearest = false
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

    func answer(_ question: String, context: Context, history: [Turn]) async throws -> Answer {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(question, context: context, history: history))

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
        let output = try JSONDecoder().decode(Output.self, from: Data(text.utf8))
        let reply = output.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw ClientError.noOutput }
        let placeID = UUID(uuidString: output.placeId).flatMap { id in context.places.contains { $0.id == id } ? id : nil }
        return Answer(reply: reply, placeID: placeID, wantsDirections: output.directions ?? false,
                      wantsNearest: output.nearest ?? false)
    }

    private func body(_ question: String, context: Context, history: [Turn]) -> [String: Any] {
        var contents: [[String: Any]] = []
        for turn in history {
            contents.append(["role": "user", "parts": [["text": turn.question]]])
            contents.append(["role": "model", "parts": [["text": Self.json(["reply": turn.reply, "placeId": ""])]]])
        }
        contents.append(["role": "user", "parts": [["text": question]]])
        return [
            "systemInstruction": ["parts": [["text": Self.instructions(for: context)]]],
            "contents": contents,
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": Self.schema(for: context),
                "thinkingConfig": ["thinkingLevel": "LOW"],
            ],
        ]
    }

    static func instructions(for context: Context) -> String {
        let places = context.places.map { place in
            var line = "- id \(place.id.uuidString): \(place.name) (\(place.kind)), Floor \(place.floor)"
            if !place.nearby.isEmpty { line += ", near \(place.nearby.joined(separator: " and "))" }
            if let note = place.note { line += ", \(note)" }
            if let distance = place.distance { line += ", about \(Int(distance.rounded())) m from the person" }
            return line
        }
        return """
        You are InView's voice assistant for \(context.buildingName). People ask where things are, and many \
        use a wheelchair, have low vision or need step-free routes. Your reply is read aloud, so:
        - Answer in one or two short sentences, under 40 words, in plain speech: no lists, markdown, emoji, \
        IDs or coordinates.
        - Use only the places listed below. Never invent rooms, room numbers, distances or turn-by-turn steps.
        - If a listed place answers the question, say which floor it is on and what it is near, and set \
        placeId to its id. If several match, mention the one on the person's floor first.
        - If the place isn't listed, such as a numbered room, say plainly that it isn't on InView's map yet. \
        You may add that room numbers usually start with the floor number, so it is likely on that floor, but \
        present that as a guess. Then suggest a listed place that could help, such as a desk or the lifts.
        - When someone needs to change floors, point them to the lifts or elevators, not stairs.
        - If they ask for the nearest or closest place of a kind and distances are listed, pick the closest one. \
        The map then draws the way there, so you can say "I'll show you the way" instead of giving steps.
        - If the question isn't about finding places in this building, say briefly that you can help find \
        places here.
        Leave placeId empty unless exactly one listed place answers the question.
        Set directions to true when the person wants to go to or find the place, as in "where is", "how do I get \
        to", "take me to" or "nearest". Set nearest to true when any place of that kind would do, as in "the \
        nearest elevator" or "a restroom", rather than one particular place.

        The person is looking at Floor \(context.currentFloor).
        Floors:
        \(context.floorSummary.map { "- \($0)" }.joined(separator: "\n"))
        Places:
        \(places.isEmpty ? "- none mapped yet" : places.joined(separator: "\n"))
        """
    }

    /// Constrains placeId to a listed id, or empty.
    private static func schema(for context: Context) -> [String: Any] {
        [
            "type": "object",
            "required": ["reply", "placeId", "directions", "nearest"],
            "properties": [
                "reply": ["type": "string"],
                "placeId": ["type": "string", "enum": [""] + context.places.map(\.id.uuidString)],
                "directions": ["type": "boolean"],
                "nearest": ["type": "boolean"],
            ],
        ]
    }

    private static func json(_ object: [String: String]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private struct Output: Decodable {
        let reply: String
        let placeId: String
        let directions: Bool?
        let nearest: Bool?
    }
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
