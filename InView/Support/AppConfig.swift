import Foundation

/// Build-time settings from Config/*.xcconfig, passed through Info.plist.
enum AppConfig {
    /// Which vision model spots elevators, ramps and stairs while scanning.
    static var visionProvider: VisionProvider { value(for: "VisionProvider").flatMap(VisionProvider.init) ?? .openai }

    static var openAIKey: String? { value(for: "OPENAIAPIKey") }
    static var openAIModel: String { value(for: "OPENAIModel") ?? "gpt-6.1-sol" }
    static var openAIReasoningEffort: String? { value(for: "OPENAIReasoningEffort") }

    static var geminiKey: String? { value(for: "GeminiAPIKey") }
    static var geminiModel: String { value(for: "GeminiModel") ?? "gemini-3.8-flash" }

    static var elevenLabsKey: String? { value(for: "ElevenLabsAPIKey") }
    static var elevenLabsVoiceID: String { value(for: "ElevenLabsVoiceID") ?? "21m00Tcm4TlvDq8ikWAM" }
    static var elevenLabsModel: String { value(for: "ElevenLabsModel") ?? "eleven_turbo_v2_5" }

    static var mapboxAccessToken: String? {
        guard let token = value(for: "MBXAccessToken"), token.hasPrefix("pk.") else { return nil }
        return token
    }

    static var backendAddress: String {
        if let saved = UserDefaults.standard.string(forKey: "roomProcessingAddress") { return saved }
        if let configured = value(for: "InViewBackendURL") { return configured }
        return ""
    }

    static var backendURL: URL? { validatedBackendURL(backendAddress) }

    static func validatedBackendURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func setBackendAddress(_ address: String) {
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roomProcessingAddress")
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
