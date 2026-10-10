import Foundation

/// Synthesizes one line of navigation speech with ElevenLabs. Nil when no API key is configured.
struct ElevenLabsVoiceClient {
    enum ClientError: LocalizedError {
        case http(status: Int, message: String)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): "ElevenLabs \(status): \(message)"
            case .empty: "ElevenLabs returned no audio"
            }
        }
    }

    private let apiKey: String
    private let voiceID: String
    private let modelID: String

    init?() {
        guard let apiKey = AppConfig.elevenLabsKey else { return nil }
        self.apiKey = apiKey
        voiceID = AppConfig.elevenLabsVoiceID
        modelID = AppConfig.elevenLabsModel
    }

    /// MP3 audio for this line, or throws on any failure. Callers are expected to apply their own
    /// timeout and fall back to an on-device voice; this makes no retry attempts of its own.
    func synthesize(_ text: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = String(decoding: data.prefix(300), as: UTF8.self)
            throw ClientError.http(status: status, message: message)
        }
        guard !data.isEmpty else { throw ClientError.empty }
        return data
    }
}
