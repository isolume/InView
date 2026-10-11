import Foundation
import Security

/// Build-time settings from Config/*.xcconfig, passed through Info.plist.
enum AppConfig {
    static var detailedScanning: Bool { UserDefaults.standard.bool(forKey: "detailedScanning") }

    /// The hosted server from Config/Secrets.xcconfig.
    static var hostedBackendAddress: String { value(for: "InViewBackendURL") ?? "" }
    /// A developer's own server on the same network (INVIEW_LOCAL_BACKEND_URL), if the build names one.
    static var localBackendAddress: String? { value(for: "InViewLocalBackendURL") }
    static var hasLocalBackend: Bool { localBackendAddress != nil }

    /// Whether the build's local server is in use instead of the hosted one. The build flag
    /// INVIEW_USE_LOCAL_BACKEND sets the default; the settings toggle overrides it on this phone.
    static var usesLocalBackend: Bool {
        guard hasLocalBackend else { return false }
        if let chosen = UserDefaults.standard.object(forKey: "useLocalBackend") as? Bool { return chosen }
        return ["YES", "TRUE", "1"].contains((value(for: "InViewUseLocalBackend") ?? "").uppercased())
    }

    static func setUsesLocalBackend(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "useLocalBackend")
    }

    /// The server this build points at: local when chosen, otherwise hosted.
    static var builtInBackendAddress: String {
        usesLocalBackend ? (localBackendAddress ?? hostedBackendAddress) : hostedBackendAddress
    }

    /// The build's server, unless one was typed into settings for this same build. A new build that
    /// points somewhere else wins over an old override, so a phone never sticks to a retired server.
    static var backendAddress: String {
        let defaults = UserDefaults.standard
        let builtIn = builtInBackendAddress
        if let saved = defaults.string(forKey: "roomProcessingAddress"), !saved.isEmpty,
           (defaults.string(forKey: "roomProcessingBuiltInAddress") ?? "") == builtIn {
            return saved
        }
        return builtIn
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
        let defaults = UserDefaults.standard
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtIn = builtInBackendAddress
        if trimmed.isEmpty || trimmed == builtIn {
            defaults.removeObject(forKey: "roomProcessingAddress")
            defaults.removeObject(forKey: "roomProcessingBuiltInAddress")
        } else {
            defaults.set(trimmed, forKey: "roomProcessingAddress")
            defaults.set(builtIn, forKey: "roomProcessingBuiltInAddress")
        }
    }

    private static let tokenService = "org.inview.scan-backend"

    /// Credentials never follow a changed server to a different origin, including a different port.
    static func backendOrigin(_ address: String) -> String? {
        guard let url = validatedBackendURL(address), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// This processing credential is deliberately separate from the signed-in account session.
    /// A token entered in settings wins; otherwise the one built in from Config/Secrets.xcconfig,
    /// which is only ever sent to the build's own servers (hosted or local; both run with that token).
    static var backendToken: String? {
        if let entered = backendToken(for: backendAddress) { return entered }
        guard let builtIn = value(for: "InViewBackendToken"), let origin = backendOrigin(backendAddress),
              [hostedBackendAddress, localBackendAddress ?? ""].compactMap(backendOrigin).contains(origin) else { return nil }
        return builtIn
    }

    static var hasBuiltInBackendToken: Bool { value(for: "InViewBackendToken") != nil }

    /// Only what was typed in settings for this server, so the field never reveals the built-in token.
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
