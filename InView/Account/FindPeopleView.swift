import AccessCore
import SwiftUI

/// Opt in to being found, look someone up by exact email or handle, or see which contacts are on
/// InView. Nobody is searchable until they turn it on here.
struct FindPeopleView: View {
    @ObservedObject private var session = AccountSession.shared
    @State private var settings: DiscoverySettings?
    @State private var handle = ""
    @State private var query = ""
    @State private var found: PersonMatch?
    @State private var contactMatches: [(match: PersonMatch, contact: String)] = []
    @State private var contactsChecked = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("Let people find me", isOn: Binding(
                    get: { settings?.discoverable ?? false },
                    set: { value in Task { await save(discoverable: value) } }))
                    .disabled(settings == nil || busy)
                HStack {
                    TextField("Handle (optional)", text: $handle)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save") { Task { await saveHandle() } }
                        .disabled(busy || HandleRules.normalized(handle) == nil || HandleRules.normalized(handle) == settings?.handle)
                }
            } header: { Text("Be found") } footer: {
                Text(footer)
            }

            Section {
                TextField("Email or handle", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    .submitLabel(.search).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .disabled(busy || query.trimmingCharacters(in: .whitespaces).count < 3)
                if let found { PersonRow(title: found.name, subtitle: found.handle.map { "@\($0)" }) }
            } header: { Text("Find someone") } footer: {
                Text("Only people who turned on “Let people find me” can be found, and only by their exact email or handle.")
            }

            Section {
                Button { Task { await matchContacts() } } label: {
                    HStack { Label("Find friends from Contacts", systemImage: "person.2"); Spacer(); if busy { ProgressView() } }
                }.disabled(busy)
                ForEach(contactMatches, id: \.match.id) { item in
                    PersonRow(title: item.contact, subtitle: item.match.name == item.contact ? nil : "On InView as \(item.match.name)")
                }
                if contactsChecked && contactMatches.isEmpty {
                    Text("None of your contacts have chosen to be found yet.").foregroundStyle(.secondary)
                }
            } header: { Text("Contacts") } footer: {
                Text("InView turns each contact’s email into a one-way code on your phone and sends only those codes. Nothing is stored, and people only appear if they chose to be found.")
            }

            if let message { Section { Text(message).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) } }
        }
        .navigationTitle("Find people")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var footer: String {
        guard let settings else { return "Loading…" }
        if !settings.discoverable { return "You’re hidden. Nobody can find you by email or handle." }
        var parts = ["People can find you"]
        if settings.emailSearchable { parts.append("by your email") }
        if settings.handle != nil { parts.append("by your handle") }
        if !settings.emailSearchable && settings.handle == nil {
            return "Your email is private (Hide My Email). Choose a handle so people can find you."
        }
        return parts.joined(separator: " ") + "."
    }

    private func load() async {
        await run { client, token in
            settings = try await client.discovery(token: token)
            handle = settings?.handle ?? ""
        }
    }

    private func save(discoverable: Bool) async {
        await run { client, token in settings = try await client.setDiscovery(discoverable: discoverable, token: token) }
    }

    private func saveHandle() async {
        guard let value = HandleRules.normalized(handle) else { return }
        await run { client, token in
            settings = try await client.setDiscovery(handle: value, token: token)
            handle = settings?.handle ?? value
        }
    }

    private func search() async {
        found = nil
        await run { client, token in found = try await client.findPerson(query, token: token) }
    }

    private func matchContacts() async {
        contactMatches = []
        contactsChecked = false
        await run { client, token in
            let book = ContactBook(entries: try await ContactsReader.entries())
            var matches: [PersonMatch] = []
            for batch in book.batches { matches += try await client.matchContacts(hashes: batch, token: token) }
            contactMatches = matches.compactMap { match in
                guard let hash = match.hash else { return nil }
                return (match, book.contactNames(for: hash).first ?? match.name)
            }
            contactsChecked = true
        }
    }

    private func run(_ work: @escaping (CommunityClient, String) async throws -> Void) async {
        guard let token = session.token, let client = try? CommunityClient() else {
            message = "Sign in to find people."
            return
        }
        busy = true
        message = nil
        defer { busy = false }
        do { try await work(client, token) }
        catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

private struct PersonRow: View {
    let title: String
    let subtitle: String?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
