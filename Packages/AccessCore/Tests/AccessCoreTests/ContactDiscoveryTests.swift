import Foundation
import Testing
@testable import AccessCore

@Test func contactHashMatchesTheServersConstruction() {
    // Same vector as backend/tests/auth0.rs: SHA-256("inview-contacts-v1:alice@example.test").
    #expect(ContactHash.hash(email: "alice@example.test")
            == "6c24d8c5cc4d10c851f11e34a2f24c394498fd928dc57b4aa858c47e25ab8b00")
    #expect(ContactHash.hash(email: "  Alice@Example.TEST ") == ContactHash.hash(email: "alice@example.test"))
}

@Test func malformedAddressesAreNotHashed() {
    for bad in ["", "alice", "alice@", "@example.test", "a@b", "a@.test", "a b@example.test", "a@b@c.test"] {
        #expect(ContactHash.hash(email: bad) == nil, "\(bad)")
    }
}

@Test func addressBookKeepsDistinctHashesAndMapsBackToContacts() {
    let book = ContactBook(entries: [
        .init(name: "Ada", emails: ["ada@example.test", "ADA@example.test", "not an email"]),
        .init(name: "Ada (work)", emails: ["ada@example.test"]),
        .init(name: "Grace", emails: ["grace@example.test"]),
    ])
    #expect(book.hashes.count == 2)
    let ada = ContactHash.hash(email: "ada@example.test")!
    #expect(book.contactNames(for: ada) == ["Ada", "Ada (work)"])
    #expect(book.contactNames(for: String(repeating: "0", count: 64)).isEmpty)
}

@Test func largeAddressBooksAreSentInBatches() {
    let entries = (0..<1_203).map { ContactBook.Entry(name: "C\($0)", emails: ["c\($0)@example.test"]) }
    let book = ContactBook(entries: entries)
    #expect(book.batches.map(\.count) == [500, 500, 203])
    #expect(Set(book.batches.flatMap { $0 }).count == 1_203)
}

@Test func handlesFollowTheServersRules() {
    #expect(HandleRules.normalized("  @Ada.L ") == "ada.l")
    for bad in ["ab", "has space", "-lead", String(repeating: "a", count: 25), "emo😀ji", "a@b.c", "é_clair"] {
        #expect(HandleRules.normalized(bad) == nil, "\(bad)")
    }
}

@Test func matchesDecodeOnlyWhatTheServerSends() throws {
    let json = Data(#"{"hash":"abc","person_id":"p1","name":"Ada Lovelace","handle":"ada.l"}"#.utf8)
    let match = try JSONDecoder().decode(PersonMatch.self, from: json)
    #expect(match.personID == "p1" && match.name == "Ada Lovelace" && match.handle == "ada.l" && match.hash == "abc")
    let settings = try JSONDecoder().decode(DiscoverySettings.self,
        from: Data(#"{"discoverable":true,"handle":null,"email_searchable":false}"#.utf8))
    #expect(settings == DiscoverySettings(discoverable: true, handle: nil, emailSearchable: false))
}
