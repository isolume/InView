import Foundation

/// Build-time settings from Config/*.xcconfig, passed through Info.plist.
enum AppConfig {
    static var geminiKey: String? { value(for: "GeminiAPIKey") }
    static var geminiModel: String { value(for: "GeminiModel") ?? "gemini-3.8-flash" }

    static var elevenLabsKey: String? { value(for: "ElevenLabsAPIKey") }
    static var elevenLabsVoiceID: String { value(for: "ElevenLabsVoiceID") ?? "EXAVITQu4vr4xnSDxMaL" }
    static var elevenLabsModel: String { value(for: "ElevenLabsModel") ?? "eleven_flash_v2_5" }

    /// Base URL of the live-status server, or nil when none is configured.
    static var serverURL: URL? {
        guard let host = value(for: "ServerHost") else { return nil }
        return URL(string: "\(value(for: "ServerScheme") ?? "https")://\(host)")
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
