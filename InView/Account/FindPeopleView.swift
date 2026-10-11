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
    @State private var shares: [PersonShare] = []
    @ObservedObject private var location = PeopleLocationService.shared

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
                if let found {
                    PersonRow(title: found.name, subtitle: found.handle.map { "@\($0)" })
                    shareButtons(for: found)
                }
            } header: { Text("Find someone") } footer: {
                Text("Only people who turned on “Let people find me” can be found, and only by their exact email or handle.")
            }

            Section {
                Button { Task { await matchContacts() } } label: {
                    HStack { Label("Find friends from Contacts", systemImage: "person.2"); Spacer(); if busy { ProgressView() } }
                }.disabled(busy)
                ForEach(contactMatches, id: \.match.id) { item in
                    PersonRow(title: item.contact, subtitle: item.match.name == item.contact ? nil : "On InView as \(item.match.name)")
                    shareButtons(for: item.match)
                }
                if contactsChecked && contactMatches.isEmpty {
                    Text("None of your contacts have chosen to be found yet.").foregroundStyle(.secondary)
                }
            } header: { Text("Contacts") } footer: {
                Text("InView turns each contact’s email into a one-way code on your phone and sends only those codes. Nothing is stored, and people only appear if they chose to be found.")
            }

            if !shares.isEmpty {
                Section {
                    ForEach(shares) { share in shareRow(share) }
                } header: { Text("Location sharing") } footer: {
                    Text("Sharing is always your choice, ends on its own, and you can stop it at any time. Your position is only sent while someone you chose can see it, and only when you’re located on the shared map.")
                }
            }

            if let message { Section { Text(message).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) } }
        }
        .navigationTitle("Find people")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private func shareButtons(for person: PersonMatch) -> some View {
        HStack {
            Button("Share my location") { Task { await startShare(person, offering: true) } }
            Spacer()
            Button("Ask for theirs") { Task { await startShare(person, offering: false) } }
        }
        .buttonStyle(.bordered).controlSize(.small).disabled(busy)
    }

    @ViewBuilder private func shareRow(_ share: PersonShare) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shareTitle(share)).font(.body.weight(.medium))
            if let detail = shareDetail(share) { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                if share.needsMyAnswer {
                    Button("Share for 1 hour") { Task { await respond(share, accept: true) } }
                    Button("Decline", role: .destructive) { Task { await respond(share, accept: false) } }
                } else if share.canFollow {
                    Button("Directions to them", systemImage: "location.fill") {
                        location.follow(share.person)
                        message = "Open the map to follow \(share.person.name)."
                    }
                    Button("Stop", role: .destructive) { Task { await end(share) } }
                } else if share.state == .active || share.state == .requested {
                    Button(share.direction == .outgoing ? "Stop sharing" : "Cancel", role: .destructive) { Task { await end(share) } }
                }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(busy)
        }
    }

    private func shareTitle(_ share: PersonShare) -> String {
        switch (share.direction, share.state) {
        case (.outgoing, .requested) where !share.startedByMe: "\(share.person.name) wants to see where you are"
        case (.outgoing, .requested): "Waiting for \(share.person.name)"
        case (.outgoing, .active): "You’re sharing your location with \(share.person.name)"
        case (.incoming, .requested): "Waiting for \(share.person.name) to accept"
        case (.incoming, .active): "\(share.person.name) is sharing their location"
        default: share.person.name
        }
    }

    private func shareDetail(_ share: PersonShare) -> String? {
        guard share.state == .active, let end = share.expiresAt else { return nil }
        return "Until \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func startShare(_ person: PersonMatch, offering: Bool) async {
        await run { client, token in
            _ = try await client.startShare(personID: person.personID, offering: offering, token: token)
            shares = try await client.shares(token: token).filter(\.isVisibleHere)
            message = offering ? "Sharing your location with \(person.name) for 1 hour." : "Asked \(person.name) to share. You’ll see directions once they accept."
        }
    }

    private func respond(_ share: PersonShare, accept: Bool) async {
        await run { client, token in
            _ = try await client.respondToShare(id: share.id, accept: accept, token: token)
            shares = try await client.shares(token: token).filter(\.isVisibleHere)
        }
    }

    private func end(_ share: PersonShare) async {
        await run { client, token in
            try await client.endShare(id: share.id, token: token)
            if location.followed?.personID == share.person.personID { location.stopFollowing() }
            shares = try await client.shares(token: token).filter(\.isVisibleHere)
        }
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
            shares = try await client.shares(token: token).filter(\.isVisibleHere)
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

private extension PersonShare {
    /// Ended and declined shares are history; the screen only lists what is open.
    var isVisibleHere: Bool { state == .requested || state == .active }
}
