import Foundation

/// Turns short prompts into speech with ElevenLabs.
struct ElevenLabsClient {
    enum ClientError: LocalizedError {
        case http(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .http(let status, let message): "ElevenLabs \(status): \(message)"
            }
        }
    }

    private let apiKey: String
    private let voiceID: String
    private let model: String

    /// Nil when no API key is configured.
    init?() {
        guard let apiKey = AppConfig.elevenLabsKey else { return nil }
        self.apiKey = apiKey
        voiceID = AppConfig.elevenLabsVoiceID
        model = AppConfig.elevenLabsModel
    }

    /// MP3 audio for the text.
    func speech(for text: String) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClientError.http(status: status, message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
}
