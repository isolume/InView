import SwiftUI

struct MySubmissionsView: View {
    @ObservedObject private var session = AccountSession.shared
    @ObservedObject private var store = ContributionStore.shared
    @State private var selectedSubmission: CommunitySubmission?
    @State private var showsAccount = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !session.isSignedIn {
                    Section {
                        ContentUnavailableView("Sign in to see your scans", systemImage: "person.crop.circle",
                                               description: Text("Follow reviews and retry saved uploads from your account."))
                        Button("Sign in") { showsAccount = true }
                    }
                } else {
                    let pending = store.drafts.filter { $0.uploadedSubmissionID == nil }
                    if !pending.isEmpty {
                        Section("Saved on this device") {
                            ForEach(pending) { draft in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Image(systemName: "arrow.up.doc").foregroundStyle(.blue).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(draft.title).font(.headline)
                                            Text("Floor \(draft.floor) · Ready to upload").font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                    if let lastError = draft.lastError { Text(lastError).font(.footnote).foregroundStyle(.secondary) }
                                    Button {
                                        Task {
                                            do { try await store.upload(draft) }
                                            catch { errorMessage = error.localizedDescription }
                                        }
                                    } label: {
                                        HStack {
                                            Text(store.uploadingIDs.contains(draft.id) ? "Uploading…" : "Retry upload")
                                            if store.uploadingIDs.contains(draft.id) { ProgressView() }
                                        }
                                    }.disabled(store.uploadingIDs.contains(draft.id) || !session.isConfigured)
                                }
                                .padding(.vertical, 5)
                                .swipeActions {
                                    Button("Remove", role: .destructive) {
                                        do { try store.remove(draft) } catch { errorMessage = error.localizedDescription }
                                    }.disabled(store.uploadingIDs.contains(draft.id))
                                }
                            }
                        }
                    }
                    if !store.submissions.isEmpty {
                        Section("Submitted") {
                            ForEach(store.submissions) { submission in
                                Button { selectedSubmission = submission } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: submission.statusSymbol)
                                            .foregroundStyle(submission.status == "published" ? .green : .blue)
                                            .frame(width: 24).accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(submission.displayTitle).foregroundStyle(.primary)
                                            Text("Floor \(submission.floor) · \(submission.statusTitle)")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }.padding(.vertical, 4)
                                }
                            }
                        }
                    } else if pending.isEmpty && !store.isRefreshing && store.errorMessage == nil {
                        ContentUnavailableView("No submissions yet", systemImage: "tray",
                                               description: Text("Your submitted scans and review updates appear here."))
                    }
                    if store.isRefreshing { ProgressView("Checking submissions…") }
                    if let message = store.errorMessage ?? errorMessage {
                        Section {
                            Text(message).foregroundStyle(.secondary)
                            Button("Try again") { Task { errorMessage = nil; await store.refresh() } }
                        }
                    }
                }
            }
            .navigationTitle("My submissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .refreshable { await store.refresh() }
            .task(id: session.account?.id) { await store.refresh() }
            .sheet(isPresented: $showsAccount) { AccountExperienceView() }
            .sheet(item: $selectedSubmission) { submission in
                SubmissionDetailView(submission: submission)
            }
        }
    }
}

private struct SubmissionDetailView: View {
    let submission: CommunitySubmission
    @ObservedObject private var store = ContributionStore.shared
    @State private var showsRevision = false
    @Environment(\.dismiss) private var dismiss

    private var latestSubmission: CommunitySubmission { store.submissions.first { $0.id == submission.id } ?? submission }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Building", value: "Student Center East")
                    LabeledContent("Floor", value: "\(latestSubmission.floor)")
                    LabeledContent("Status", value: latestSubmission.statusTitle)
                    LabeledContent("Submitted") { Text(Date(timeIntervalSince1970: latestSubmission.createdAt), style: .date) }
                    if let version = latestSubmission.publishedVersion { LabeledContent("Map version", value: "\(version)") }
                }
                if let note = latestSubmission.reviewNote, !note.isEmpty {
                    Section("Review") { Text(note) }
                }
                if latestSubmission.status == "changes_requested" {
                    Section { Button("Upload revised scan") { showsRevision = true } }
                }
            }
            .navigationTitle(submission.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showsRevision, onDismiss: { Task { await ContributionStore.shared.refresh() } }) {
                ContributeExperienceView(submission: latestSubmission)
            }
        }
    }
}
