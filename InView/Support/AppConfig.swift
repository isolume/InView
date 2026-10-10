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

    private static let tokenService = "org.inview.scan-backend"
    private static let tokenAccount = "api-access-token"

    static var backendToken: String? {
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
        UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "roomProcessingAddress")
    }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}
