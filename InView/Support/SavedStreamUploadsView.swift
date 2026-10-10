import AccessCore
import SwiftUI

/// Reopening the app never sends saved camera samples automatically. A volunteer can
/// explicitly resume a retained stream, using its original server or a newly selected one.
struct SavedStreamUploadsView: View {
    private struct SavedScan: Identifiable, Sendable {
        var manifest: StreamManifest
        var root: URL
        var date: Date
        var id: String { manifest.id }
    }
    @State private var scans: [SavedScan] = []
    @State private var busyID: String?
    @State private var status: [String: String] = [:]
    @State private var preview: StreamResult?
    @State private var evidenceScanID: String?
    @State private var task: Task<Void, Never>?
    @State private var listingError: String?

    var body: some View {
        List {
            if scans.isEmpty {
                Text(listingError ?? "No saved continuous scans.").foregroundStyle(.secondary)
            }
            ForEach(scans) { scan in
                VStack(alignment: .leading, spacing: 8) {
                    Text(scan.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    if let message = status[scan.id] { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button("View scan data") { evidenceScanID = scan.id }
                    Button {
                        resume(scan)
                    } label: {
                        if busyID == scan.id { ProgressView("Building model…") }
                        else { Text("Resume upload and view model") }
                    }
                    .disabled(busyID != nil)
                    if AppConfig.backendURL != nil {
                        Button("Send to selected server") { resume(scan, moveToSelectedServer: true) }
                            .disabled(busyID != nil)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Saved scans")
        .task {
            do { scans = try await ScanWork.run(priority: .utility) { try Self.savedScans() } }
            catch { listingError = error.localizedDescription }
        }
        .onDisappear { task?.cancel() }
        .fullScreenCover(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                RoomMapExperience(scene: preview.scene, title: "Saved scan", onClose: { self.preview = nil },
                                  streamEvidenceID: preview.capture.id)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { evidenceScanID != nil }, set: { if !$0 { evidenceScanID = nil } })) {
            if let evidenceScanID { RawLidarReviewView(scanID: evidenceScanID) }
        }
    }

    private func resume(_ scan: SavedScan, moveToSelectedServer: Bool = false) {
        busyID = scan.id
        let selectedServer = AppConfig.backendURL
        task = Task {
            defer { busyID = nil }
            do {
                let queue = try await ScanWork.run(priority: .utility) {
                    // nil preserves the original server binding from the checkpoint.
                    try StreamingCaptureQueue(root: scan.root, manifest: scan.manifest, backendURL: nil)
                }
                if moveToSelectedServer, let selectedServer {
                    try await queue.configureBackend(selectedServer)
                }
                do {
                    _ = try await queue.finish()
                } catch StreamingCaptureError.notConfigured {
                    guard let selectedServer else { throw StreamingCaptureError.notConfigured }
                    try await queue.configureBackend(selectedServer)
                    _ = try await queue.finish()
                }
                let result = try await queue.result()
                try await ScanWork.run(priority: .utility) {
                    try JSONEncoder().encode(result).write(to: scan.root.appending(path: "result.json"), options: .atomic)
                }
                status[scan.id] = "Uploaded. Model ready for review."
                preview = result
            } catch is CancellationError {
                status[scan.id] = "Paused. Your scan is saved on this phone."
            } catch {
                status[scan.id] = error.localizedDescription
            }
        }
    }

    private nonisolated static func savedScans() throws -> [SavedScan] {
        let root = URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .compactMap { directory in
                guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
                let stream = directory.appending(path: "stream", directoryHint: .isDirectory)
                let manifestURL = stream.appending(path: "manifest.json")
                guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
                let manifest = try JSONDecoder().decode(StreamManifest.self, from: Data(contentsOf: manifestURL))
                try manifest.validate()
                guard manifest.id == directory.lastPathComponent else { return nil }
                let date = try directory.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
                return SavedScan(manifest: manifest, root: stream, date: date)
            }
            .sorted { $0.date > $1.date }
    }
}
