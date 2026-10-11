import Foundation

/// Where a bearer token may travel. HTTPS always; plain HTTP only to this phone's own machine or a
/// private-network address, which is what a developer's Mac on the same Wi-Fi looks like. A public
/// plain-HTTP host never receives a credential.
public enum BackendTransport {
    public static func allowsCredential(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return isLocalNetworkHost(host)
    }

    /// Loopback, RFC 1918 and link-local IPv4, IPv6 loopback/unique-local/link-local, and `.local` names.
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if let v4 = ipv4Octets(host) {
            switch (v4[0], v4[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        // IPv6 (zone ids like fe80::1%en0 included).
        let v6 = host.split(separator: "%").first.map(String.init) ?? host
        if v6 == "::1" { return true }
        if v6.hasPrefix("fe8") || v6.hasPrefix("fe9") || v6.hasPrefix("fea") || v6.hasPrefix("feb") { return true }
        if v6.hasPrefix("fc") || v6.hasPrefix("fd") { return true }
        return false
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }
}
