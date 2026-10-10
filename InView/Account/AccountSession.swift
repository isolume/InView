import Foundation
import Security
import SwiftUI

@MainActor
final class AccountSession: ObservableObject {
    static let shared = AccountSession()

    @Published private(set) var account: CommunityAccount?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    private(set) var token: String?

    var isSignedIn: Bool { account != nil && token != nil }
    var isConfigured: Bool { (try? CommunityClient()) != nil }
    var configurationMessage: String? {
        do { _ = try CommunityClient(); return nil }
        catch { return error.localizedDescription }
    }

    private struct StoredSession: Codable {
        let address: String
        let token: String
        let account: CommunityAccount
    }

    private init() {
        guard let data = Self.savedData(), let saved = try? JSONDecoder().decode(StoredSession.self, from: data),
              saved.address == CommunityClient.configuredURL?.absoluteString else { return }
        account = saved.account
        token = saved.token
    }

    func authenticate(email: String, password: String, name: String?, registering: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let client = try CommunityClient()
            let result = try await client.authenticate(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                                                       name: name?.trimmingCharacters(in: .whitespacesAndNewlines), registering: registering)
            try persist(result, address: client.baseURL.absoluteString)
            account = result.account
            token = result.token
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshAccount() async {
        guard let token, !isWorking else { return }
        do {
            let client = try CommunityClient()
            let refreshed = try await client.account(token: token)
            guard self.token == token else { return }
            try persist(CommunityAuthentication(token: token, account: refreshed), address: client.baseURL.absoluteString)
            account = refreshed
        } catch CommunityError.sessionExpired {
            guard self.token == token else { return }
            clearSession()
            errorMessage = CommunityError.sessionExpired.localizedDescription
        } catch {
            guard self.token == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        let previousToken = token
        // Removing local credentials always succeeds independently of service connectivity.
        clearSession()
        if let previousToken, let client = try? CommunityClient() { try? await client.logout(token: previousToken) }
        isWorking = false
        errorMessage = nil
    }

    func expireSession() {
        clearSession()
        errorMessage = CommunityError.sessionExpired.localizedDescription
    }

    private func clearSession() {
        token = nil
        account = nil
        SecItemDelete(Self.keychainQuery as CFDictionary)
    }

    private func persist(_ authentication: CommunityAuthentication, address: String) throws {
        let data = try JSONEncoder().encode(StoredSession(address: address, token: authentication.token, account: authentication.account))
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.keychainQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CommunityError.keychain }
        } else if status != errSecSuccess { throw CommunityError.keychain }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "InView").account",
         kSecAttrAccount as String: "session"]
    }

    private static func savedData() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
