import Foundation
import Security

/// Build-time settings from Config/*.xcconfig, passed through Info.plist.
enum AppConfig {
    /// The streaming branch defaults to the continuous scanner; RoomPlan remains available for comparison.
    static var continuousScanning: Bool {
        UserDefaults.standard.object(forKey: "continuousScanning") as? Bool ?? true
    }

    static func setContinuousScanning(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "continuousScanning")
    }

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

    /// The build's server, unless one was typed into settings for this same build. A new build that
    /// points somewhere else wins over an old override, so a phone never sticks to a retired server.
    static var backendAddress: String {
        let defaults = UserDefaults.standard
        let builtIn = value(for: "InViewBackendURL") ?? ""
        if let saved = defaults.string(forKey: "roomProcessingAddress"), !saved.isEmpty,
           (defaults.string(forKey: "roomProcessingBuiltInAddress") ?? "") == builtIn {
            return saved
        }
        return builtIn
    }

    static var backendURL: URL? { validatedBackendURL(backendAddress) }

    private static let tokenService = "org.inview.scan-backend"
    private static let tokenAccount = "api-access-token"

    /// A token entered in settings wins; otherwise the one built in from Config/Secrets.xcconfig.
    static var backendToken: String? { keychainBackendToken ?? value(for: "InViewBackendToken") }

    static var hasBuiltInBackendToken: Bool { value(for: "InViewBackendToken") != nil }
    /// Only what was typed in settings, so the field never reveals the built-in token.
    static var enteredBackendToken: String? { keychainBackendToken }

    private static var keychainBackendToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let bytes = item as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    @discardableResult static func setBackendToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount
        ]
        if trimmed.isEmpty { return [errSecSuccess, errSecItemNotFound].contains(SecItemDelete(query as CFDictionary)) }
        guard let data = trimmed.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil) == errSecSuccess
    }

    static func validatedBackendURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func setBackendAddress(_ address: String) {
        let defaults = UserDefaults.standard
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == (value(for: "InViewBackendURL") ?? "") {
            defaults.removeObject(forKey: "roomProcessingAddress")
            defaults.removeObject(forKey: "roomProcessingBuiltInAddress")
        } else {
            defaults.set(trimmed, forKey: "roomProcessingAddress")
            defaults.set(value(for: "InViewBackendURL") ?? "", forKey: "roomProcessingBuiltInAddress")
        }
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
