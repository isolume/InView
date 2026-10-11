import AccessCore
import SwiftUI
import UniformTypeIdentifiers

struct ContributeExperienceView: View {
    private let replacingSubmission: CommunitySubmission?
    @ObservedObject private var session = AccountSession.shared
    @ObservedObject private var store = ContributionStore.shared
    @State private var floor: Int
    @State private var title: String
    @State private var notes = ""
    @State private var authorized = false
    @State private var selectedMap: ContributionMap?
    @State private var showsImporter = false
    @State private var showsScanner = false
    @State private var showsAccount = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var receivedSubmission: CommunitySubmission?
    @State private var captureBeforeScan: UUID?
    @State private var uploadID = UUID()
    @Environment(\.dismiss) private var dismiss

    init(submission: CommunitySubmission? = nil) {
        replacingSubmission = submission
        let savedLevel = MapStore.currentFloor?.level
        let level = submission?.floor ?? savedLevel.flatMap { (1...3).contains($0) ? $0 : nil } ?? 2
        _floor = State(initialValue: level)
        _title = State(initialValue: submission?.displayTitle ?? "Floor \(level) scan")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let receivedSubmission {
                    Section {
                        Label("Scan submitted", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(.green)
                        Text("An admin will review your scan before it appears on the map.")
                            .foregroundStyle(.secondary)
                        LabeledContent("Status", value: receivedSubmission.statusTitle)
                        NavigationLink { MySubmissionsView() } label: { Text("My submissions") }
                    }
                } else {
                    if let configurationMessage = session.configurationMessage {
                        Section {
                            Label(configurationMessage, systemImage: "network.slash")
                                .foregroundStyle(.secondary)
                        }
                    } else if !session.isSignedIn {
                        Section {
                            Text("Sign in to submit a scan for review. You can still scan and save on this device.")
                                .foregroundStyle(.secondary)
                            Button("Sign in") { showsAccount = true }
                        }
                    }
                    if let note = replacingSubmission?.reviewNote, !note.isEmpty {
                        Section("Changes requested") { Text(note) }
                    }
                    Section {
                        Text("Student Center East").font(.headline)
                        Picker("Floor", selection: $floor) {
                            ForEach(1...3, id: \.self) { level in Text("\(level)").tag(level) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(replacingSubmission != nil)
                        .accessibilityLabel("Floor")
                    }
                    Section {
                        if let selectedMap {
                            Label(selectedMap.name, systemImage: "doc.text")
                            Text("\(selectedMap.map.footprints.count) features · \(selectedMap.map.points.count) places")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button { showsImporter = true } label: {
                            Label(selectedMap == nil ? "Choose a floor map" : "Choose a different map", systemImage: "folder")
                        }
                        if hasSavedScan {
                            Button { useSavedScan() } label: { Label("Use saved scan", systemImage: "iphone") }
                        }
                        Button {
                            captureBeforeScan = MapStore.currentFloor?.storageID
                            showsScanner = true
                        } label: { Label("Scan a space", systemImage: "viewfinder") }
                    } header: {
                        Text("Scan")
                    } footer: {
                        Text("Choose a map exported from InView or create a scan with a supported iPhone.")
                    }
                    if selectedMap != nil && !uploadIsSaved {
                        Section {
                            TextField("Scan name", text: $title)
                            TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(3...6)
                            Toggle("I have permission to share this scan", isOn: $authorized)
                        } footer: { Text("Submit only authorized spaces at Student Center East.") }
                        Section {
                            Button {
                                Task { await submit() }
                            } label: {
                                HStack {
                                    Text(uploadIsSaved ? "Saved for retry" : replacingSubmission == nil ? "Submit for review" : "Submit revised scan")
                                    Spacer()
                                    if isSubmitting { ProgressView() }
                                }
                            }
                            .disabled(!canSubmit || uploadIsSaved)
                        } footer: { Text("Your scan appears on the map after an admin approves it.") }
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                            if !store.drafts.isEmpty {
                                NavigationLink { MySubmissionsView() } label: { Text("View saved uploads") }
                            }
                        }
                    }
                }
            }
            .disabled(isSubmitting)
            .navigationTitle(replacingSubmission == nil ? "Contribute" : "Update scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(isSubmitting)
                }
            }
            .onChange(of: floor) { old, new in
                if title == "Floor \(old) scan" { title = "Floor \(new) scan" }
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
                do {
                    selectedMap = try ContributionMap.read(result.get())
                    uploadID = UUID()
                    authorized = false
                    errorMessage = nil
                } catch { errorMessage = error.localizedDescription }
            }
            .sheet(isPresented: $showsAccount) { AccountExperienceView() }
            .fullScreenCover(isPresented: $showsScanner, onDismiss: {
                if MapStore.currentFloor?.storageID != captureBeforeScan { useSavedScan() }
            }) { ScanView() }
            .task { store.loadForCurrentAccount() }
        }
    }

    private var hasSavedScan: Bool {
        MapStore.currentFloor != nil || FileManager.default.fileExists(atPath: MapStore.worldMapURL.path())
    }

    private var canSubmit: Bool {
        session.isSignedIn && session.isConfigured && authorized && selectedMap != nil && !isSubmitting &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 120 && notes.count <= 4_000
    }

    private var uploadIsSaved: Bool { store.drafts.contains { $0.id == uploadID && $0.uploadedSubmissionID == nil } }

    private func useSavedScan() {
        do {
            guard hasSavedScan, let map = MapStore.load() else { throw ContributionFileError.invalidMap }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let level = MapStore.currentFloor?.level
            if replacingSubmission == nil, let level, (1...3).contains(level) { floor = level }
            selectedMap = try ContributionMap(data: encoder.encode(map), name: MapStore.currentFloor?.name ?? "Saved scan")
            uploadID = UUID()
            authorized = false
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func submit() async {
        guard canSubmit, let selectedMap else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            receivedSubmission = try await store.submit(map: selectedMap, floor: floor, title: title, notes: notes,
                                                        replacing: replacingSubmission, uploadID: uploadID)
        } catch {
            errorMessage = "\(error.localizedDescription) Your upload is saved in My submissions so you can retry."
        }
    }
}
