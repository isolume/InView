import AccessCore
import Foundation
import SwiftUI

struct ContributionDraft: Codable, Identifiable {
    let id: UUID
    let accountID: UUID
    let floor: Int
    let title: String
    let notes: String
    let createdAt: Date
    let submissionID: UUID?
    let expectedRevision: Int?
    var uploadedSubmissionID: UUID?
    var lastError: String?
}

struct ContributionMap {
    let data: Data
    let name: String
    let map: VenueMap

    // Leave room for submission notes beneath the service's 2 MiB request limit.
    static let maximumBytes = 1_900_000

    init(data: Data, name: String) throws {
        guard data.count <= Self.maximumBytes else { throw ContributionFileError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let map: VenueMap
        do { map = try decoder.decode(VenueMap.self, from: data) }
        catch { throw ContributionFileError.invalidMap }
        guard StudentCenterCatalog.isDisplayable(map) else { throw ContributionFileError.invalidMap }
        self.data = data
        self.name = name
        self.map = map
    }

    static func read(_ url: URL) throws -> ContributionMap {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw ContributionFileError.invalidMap }
        guard let size = values.fileSize, size <= maximumBytes else { throw ContributionFileError.tooLarge }
        return try ContributionMap(data: Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent)
    }
}

enum ContributionFileError: LocalizedError {
    case invalidMap, tooLarge, missingDraft
    var errorDescription: String? {
        switch self {
        case .invalidMap: "Choose an InView floor map with valid scan measurements."
        case .tooLarge: "Choose a floor map smaller than 1.9 MB."
        case .missingDraft: "The saved upload could not be found. Choose the file again."
        }
    }
}

/// Original map files stay on-device until a confirmed service response. A stable upload ID makes retries safe.
@MainActor
final class ContributionStore: ObservableObject {
    static let shared = ContributionStore()
    @Published private(set) var submissions: [CommunitySubmission] = []
    @Published private(set) var drafts: [ContributionDraft] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var uploadingIDs: Set<UUID> = []
    @Published var errorMessage: String?
    private var loadedAccountID: UUID?

    private var directory: URL { URL.documentsDirectory.appending(path: "ContributionUploads", directoryHint: .isDirectory) }
    private func accountDirectory(_ id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }
    private func mapURL(_ draft: ContributionDraft) -> URL { accountDirectory(draft.accountID).appending(path: "\(draft.id.uuidString).json") }
    private func manifestURL(_ id: UUID) -> URL { accountDirectory(id).appending(path: "uploads.json") }

    func loadForCurrentAccount() {
        let accountID = AccountSession.shared.account?.id
        guard loadedAccountID != accountID else { return }
        loadedAccountID = accountID
        submissions = []
        drafts = []
        errorMessage = nil
        guard let accountID, let data = try? Data(contentsOf: manifestURL(accountID)) else { return }
        do {
            drafts = try JSONDecoder().decode([ContributionDraft].self, from: data).filter { $0.accountID == accountID }
        } catch { errorMessage = "Your saved uploads could not be opened. The original files are still on this device." }
    }

    func refresh() async {
        loadForCurrentAccount()
        guard let token = AccountSession.shared.token, let accountID = AccountSession.shared.account?.id else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }
        do {
            let received = try await CommunityClient().submissions(token: token)
            guard AccountSession.shared.account?.id == accountID else { return }
            submissions = received.sorted { $0.updatedAt > $1.updatedAt }
        } catch CommunityError.sessionExpired {
            if AccountSession.shared.token == token {
                AccountSession.shared.expireSession()
                loadForCurrentAccount()
            }
        } catch {
            if AccountSession.shared.account?.id == accountID { errorMessage = error.localizedDescription }
        }
    }

    func submit(map: ContributionMap, floor: Int, title: String, notes: String, replacing submission: CommunitySubmission? = nil,
                uploadID: UUID = UUID()) async throws -> CommunitySubmission {
        loadForCurrentAccount()
        guard let accountID = AccountSession.shared.account?.id else { throw CommunityError.signedOut }
        if let existing = drafts.first(where: { $0.id == uploadID && $0.accountID == accountID }) {
            return try await upload(existing)
        }
        let draft = ContributionDraft(id: uploadID, accountID: accountID, floor: floor,
                                      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                      notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: .now,
                                      submissionID: submission?.id, expectedRevision: submission?.revision)
        try FileManager.default.createDirectory(at: accountDirectory(accountID), withIntermediateDirectories: true)
        try map.data.write(to: mapURL(draft), options: [.atomic, .completeFileProtection])
        drafts.insert(draft, at: 0)
        try save(accountID: accountID)
        return try await upload(draft)
    }

    @discardableResult
    func upload(_ draft: ContributionDraft) async throws -> CommunitySubmission {
        guard draft.uploadedSubmissionID == nil else { throw CommunityError.server("This scan has already been received.") }
        guard !uploadingIDs.contains(draft.id) else { throw CommunityError.server("This scan is already uploading.") }
        guard let accountID = AccountSession.shared.account?.id, draft.accountID == accountID,
              let token = AccountSession.shared.token else { throw CommunityError.signedOut }
        uploadingIDs.insert(draft.id)
        errorMessage = nil
        defer { uploadingIDs.remove(draft.id) }
        do {
            guard FileManager.default.fileExists(atPath: mapURL(draft).path()) else { throw ContributionFileError.missingDraft }
            let data = try Data(contentsOf: mapURL(draft), options: .mappedIfSafe)
            let result = try await CommunityClient().upload(draft, mapData: data, token: token)
            guard AccountSession.shared.account?.id == accountID else { throw CommunityError.signedOut }
            if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
                drafts[index].uploadedSubmissionID = result.id
                drafts[index].lastError = nil
            }
            submissions.removeAll { $0.id == result.id }
            submissions.insert(result, at: 0)
            try save(accountID: accountID)
            return result
        } catch {
            if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
                drafts[index].lastError = error.localizedDescription
                try? save(accountID: accountID)
            }
            if case CommunityError.sessionExpired = error, AccountSession.shared.token == token {
                AccountSession.shared.expireSession()
                loadForCurrentAccount()
            }
            throw error
        }
    }

    func remove(_ draft: ContributionDraft) throws {
        guard draft.accountID == AccountSession.shared.account?.id, !uploadingIDs.contains(draft.id) else { return }
        // Persist removal first so an interrupted cleanup cannot leave a retry with no source file.
        let remaining = drafts.filter { $0.id != draft.id }
        try JSONEncoder().encode(remaining).write(to: manifestURL(draft.accountID), options: [.atomic, .completeFileProtection])
        drafts = remaining
        try? FileManager.default.removeItem(at: mapURL(draft))
    }

    private func save(accountID: UUID) throws {
        try JSONEncoder().encode(drafts.filter { $0.accountID == accountID }).write(to: manifestURL(accountID), options: [.atomic, .completeFileProtection])
    }
}
