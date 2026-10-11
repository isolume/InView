import AccessCore
import Contacts

/// Reads the email addresses in the person's address book, only after they tap "Find friends".
/// Names stay on the device to label matches; only hashes of the emails are ever sent.
enum ContactsReader {
    enum ContactsError: LocalizedError {
        case denied
        var errorDescription: String? {
            "Allow InView to read your contacts in Settings to find people you know."
        }
    }

    static func entries() async throws -> [ContactBook.Entry] {
        let store = CNContactStore()
        guard try await store.requestAccess(for: .contacts) else { throw ContactsError.denied }
        return try await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                           CNContactEmailAddressesKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var result: [ContactBook.Entry] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let emails = contact.emailAddresses.map { String($0.value) }
                guard !emails.isEmpty else { return }
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                result.append(.init(name: name.isEmpty ? "Contact" : name, emails: emails))
            }
            return result
        }.value
    }
}
