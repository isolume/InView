import Foundation

/// The Auth0 tenant and native application the app signs in with. All three values are public
/// identifiers (the application uses PKCE and has no client secret), so they may live in the repo.
public struct Auth0Settings: Equatable, Sendable {
    /// Tenant host, e.g. `inview.us.auth0.com`.
    public let domain: String
    public let clientID: String
    /// Where Universal Login returns to. Must be listed under Allowed Callback URLs in Auth0.
    public let callbackURL: URL

    /// Returns nil unless every value is well formed, so a half-configured build falls back to the
    /// previous sign-in instead of opening a broken login page.
    /// - Parameters:
    ///   - callback: The registered callback URL. Defaults to Auth0.swift's own form,
    ///     `{bundle id}://{domain}/ios/{bundle id}/callback`.
    public init?(domain: String?, clientID: String?, callback: String? = nil, bundleIdentifier: String? = nil) {
        var host = (domain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("https://") { host.removeFirst("https://".count) }
        while host.hasSuffix("/") { host.removeLast() }
        let validHost = host.count <= 253 && host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && host.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46 }
        let id = (clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let validID = (16...64).contains(id.count)
            && id.utf8.allSatisfy { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95 }
        guard validHost, validID else { return nil }

        let raw = (callback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if raw.isEmpty {
            let bundle = (bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            url = bundle.isEmpty ? nil : URL(string: "\(bundle)://\(host)/ios/\(bundle)/callback")
        } else {
            url = URL(string: raw)
        }
        // A custom scheme (not http/https): a web page must not be able to intercept the code.
        guard let url, let scheme = url.scheme?.lowercased(), !["http", "https", "file", "javascript"].contains(scheme),
              url.host?.lowercased() == host, url.path.hasSuffix("/callback"),
              url.user == nil, url.query == nil, url.fragment == nil else { return nil }
        self.domain = host
        self.clientID = id
        self.callbackURL = url
    }
}
