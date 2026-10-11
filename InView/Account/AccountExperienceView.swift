import SwiftUI

struct AccountExperienceView: View {
    @ObservedObject private var session = AccountSession.shared
    @State private var registering = false
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let account = session.account {
                    Section {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 46)).foregroundStyle(.blue)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.displayName).font(.headline)
                                if account.name?.isEmpty == false { Text(account.email).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 8)
                    }
                    Section {
                        NavigationLink { MySubmissionsView() } label: { Label("My submissions", systemImage: "tray") }
                        NavigationLink { ContributeExperienceView() } label: { Label("Contribute a scan", systemImage: "viewfinder") }
                        NavigationLink { FindPeopleView() } label: { Label("Find people", systemImage: "person.2") }
                        if account.isAdmin, let client = try? CommunityClient() {
                            Link(destination: client.adminURL) { Label("Review scans", systemImage: "checkmark.shield") }
                        }
                    }
                    Section {
                        Button("Sign out", role: .destructive) { Task { await session.signOut() } }
                            .disabled(session.isWorking)
                    }
                } else {
                    Section {
                        Text("Explore without an account. Sign in to contribute scans and follow their review.")
                            .foregroundStyle(.secondary)
                    }
                    if let configurationMessage = session.configurationMessage {
                        Section { Label(configurationMessage, systemImage: "network.slash").foregroundStyle(.secondary) }
                    } else if AppConfig.auth0 != nil {
                        Section {
                            Button {
                                Task { await session.signInWithAuth0() }
                            } label: {
                                HStack {
                                    Label("Continue with Apple or email", systemImage: "person.badge.key")
                                    Spacer()
                                    if session.isWorking { ProgressView() }
                                }
                            }.disabled(session.isWorking)
                        } footer: {
                            Text("Sign in with your Apple ID, or get a one-time code by email. There’s no password to remember.")
                        }
                    } else {
                        Section {
                            Picker("Account", selection: $registering) {
                                Text("Sign in").tag(false)
                                Text("Create account").tag(true)
                            }.pickerStyle(.segmented)
                            if registering {
                                TextField("Name (optional)", text: $name).textContentType(.name)
                            }
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress).textContentType(.emailAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Password", text: $password)
                                .textContentType(registering ? .newPassword : .password)
                            Button {
                                Task { await session.authenticate(email: email, password: password, name: registering ? name : nil, registering: registering) }
                            } label: {
                                HStack {
                                    Text(registering ? "Create account" : "Sign in")
                                    Spacer()
                                    if session.isWorking { ProgressView() }
                                }
                            }.disabled(!canAuthenticate || session.isWorking)
                        } footer: {
                            if registering { Text("Use at least 12 characters for your password.") }
                        }
                    }
                }
                if let error = session.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await session.refreshAccount() }
            .onChange(of: session.isSignedIn) { _, signedIn in if signedIn { password = "" } }
            .onChange(of: registering) { _, _ in session.errorMessage = nil }
        }
    }

    private var canAuthenticate: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && password.utf8.count <= 1_024 &&
            (registering ? password.count >= 12 : !password.isEmpty)
    }
}
