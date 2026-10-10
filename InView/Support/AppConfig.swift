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

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
