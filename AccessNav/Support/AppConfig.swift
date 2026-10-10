import Foundation

/// Build-time settings from Config/*.xcconfig, passed through Info.plist.
enum AppConfig {
    static var openAIKey: String? { value(for: "OPENAIAPIKey") }
    static var openAIModel: String { value(for: "OPENAIModel") ?? "gpt-6.1-sol" }
    static var openAIReasoningEffort: String? { value(for: "OPENAIReasoningEffort") }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
