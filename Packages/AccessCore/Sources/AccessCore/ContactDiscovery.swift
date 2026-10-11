import CryptoKit
import Foundation

/// Finding people you know without sending anyone's address book to the server in the clear.
///
/// The app hashes each contact's email on the device (`ContactHash`) and asks the server which hashes
/// belong to InView people who chose to be found. Contacts who haven't opted in come back as nothing,
/// so they look the same as someone who isn't on InView.
public enum ContactHash {
    /// Must equal the backend's `contact_hash`: lower-case hex SHA-256 of this prefix plus the address.
    static let prefix = "inview-contacts-v1:"
    /// The most the server accepts in one request.
    public static let maximumPerRequest = 500

    public static func normalized(_ email: String) -> String? {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard value.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return value
    }

    public static func hash(email: String) -> String? {
        guard let value = normalized(email) else { return nil }
        return SHA256.hash(data: Data((prefix + value).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An address book reduced to what is needed to match it: hashes to send, and how to get back to the
/// contact each came from. Emails themselves never leave the device.
public struct ContactBook: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var emails: [String]
        public init(name: String, emails: [String]) { self.name = name; self.emails = emails }
    }

    /// Distinct hashes, in first-seen order.
    public private(set) var hashes: [String] = []
    private var names: [String: [String]] = [:]

    public init(entries: [Entry]) {
        for entry in entries {
            for email in entry.emails {
                guard let hash = ContactHash.hash(email: email) else { continue }
                if names[hash] == nil { hashes.append(hash) }
                if !(names[hash] ?? []).contains(entry.name) { names[hash, default: []].append(entry.name) }
            }
        }
    }

    /// Batches that respect the server's per-request limit.
    public var batches: [[String]] {
        stride(from: 0, to: hashes.count, by: ContactHash.maximumPerRequest).map {
            Array(hashes[$0..<min($0 + ContactHash.maximumPerRequest, hashes.count)])
        }
    }

    /// The contact name(s) a returned hash came from.
    public func contactNames(for hash: String) -> [String] { names[hash] ?? [] }
}

/// Someone found by hash, exact email or handle: only what the server chooses to reveal.
public struct PersonMatch: Decodable, Equatable, Identifiable, Sendable {
    public var personID: String
    public var name: String
    public var handle: String?
    /// Present for address-book matches: the hash this person came from.
    public var hash: String?
    public var id: String { personID }

    private enum CodingKeys: String, CodingKey { case personID = "person_id", name, handle, hash }
}

public struct DiscoverySettings: Decodable, Equatable, Sendable {
    public var discoverable: Bool
    public var handle: String?
    /// Whether people with your email in their contacts can find you (not for Hide My Email addresses).
    public var emailSearchable: Bool

    public init(discoverable: Bool, handle: String?, emailSearchable: Bool) {
        self.discoverable = discoverable; self.handle = handle; self.emailSearchable = emailSearchable
    }

    private enum CodingKeys: String, CodingKey { case discoverable, handle, emailSearchable = "email_searchable" }
}

public enum HandleRules {
    /// Mirrors the server: 3...24 of letters, digits, dot and underscore, starting with a letter or digit.
    public static func normalized(_ handle: String) -> String? {
        var value = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("@") { value.removeFirst() }
        guard (3...24).contains(value.count), let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII,
              value.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_") })
        else { return nil }
        return value
    }
}
