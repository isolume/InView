import Foundation
import Security

/// Build-time settings from Config/*.xcconfig, passed through Info.plist.
enum AppConfig {
    static var detailedScanning: Bool { UserDefaults.standard.bool(forKey: "detailedScanning") }

    static var backendAddress: String {
        UserDefaults.standard.string(forKey: "roomProcessingAddress") ?? value(for: "InViewBackendURL") ?? ""
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

    private static let tokenService = "org.inview.scan-backend"

    /// Credentials never follow a changed server to a different origin, including a different port.
    static func backendOrigin(_ address: String) -> String? {
        guard let url = validatedBackendURL(address), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// This processing credential is deliberately separate from the signed-in account session.
    static var backendToken: String? { backendToken(for: backendAddress) }

    static func backendToken(for address: String) -> String? {
        guard let origin = backendOrigin(address) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService, kSecAttrAccount as String: "api-access-token@" + origin,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult static func setBackendToken(_ token: String, for address: String) -> Bool {
        guard let origin = backendOrigin(address) else { return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService, kSecAttrAccount as String: "api-access-token@" + origin
        ]
        if token.isEmpty { return [errSecSuccess, errSecItemNotFound].contains(SecItemDelete(query as CFDictionary)) }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil) == errSecSuccess
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

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
