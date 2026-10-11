import AccessCore
import SwiftUI

/// Saved captures are inspected locally. Opening this screen never resumes an upload.
struct SavedStreamUploadsView: View {
    private struct SavedScan: Identifiable, Sendable {
        var id: String
        var root: URL
        var date: Date
        var hasScene: Bool
        var hasStream: Bool
        var hasVideo: Bool
        var originalFiles: [URL]
    }

    private struct SavedPreview: Identifiable, Sendable {
        var id: String
        var scene: ProcessedScene
        var hasStream: Bool
    }

    @State private var scans: [SavedScan] = []
    @State private var busyID: String?
    @State private var preview: SavedPreview?
    @State private var evidenceScanID: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var listingError: String?
    @State private var previewError: String?
    @State private var errorTitle = "Couldn't open the map"
    @State private var isLoading = true
    @State private var videoExportURL: URL?
    @State private var videoExportID: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading scans…")
            } else if scans.isEmpty {
                Text(listingError ?? "No saved scans yet.").foregroundStyle(.secondary)
            }
            if scans.contains(where: { !$0.hasStream }) {
                Section("Scans") {
                    ForEach(scans.filter { !$0.hasStream }) { scan in
                        scanRow(scan)
                    }
                }
            }
            if scans.contains(where: \.hasStream) {
                Section {
                    ForEach(scans.filter(\.hasStream)) { scan in
                        scanRow(scan)
                    }
                } header: {
                    Text("Earlier scans")
                } footer: {
                    Text("Saved models and original evidence stay on this device.")
                }
            }
        }
        .navigationTitle("Saved scans")
        .task {
            do { scans = try await ScanWork.run(priority: .utility) { try Self.savedScans() } }
            catch is CancellationError { return }
            catch { listingError = "Saved scans couldn't be opened. Please try again." }
            isLoading = false
        }
        .onDisappear { previewTask?.cancel() }
        .fullScreenCover(item: $preview) { saved in
            RoomMapExperience(scene: saved.scene, title: "Saved scan", onClose: { preview = nil },
                              streamEvidenceID: saved.hasStream ? saved.id : nil)
        }
        .fullScreenCover(isPresented: Binding(get: { evidenceScanID != nil }, set: { if !$0 { evidenceScanID = nil } })) {
            if let evidenceScanID { RawLidarReviewView(scanID: evidenceScanID) }
        }
        .alert(errorTitle, isPresented: Binding(
            get: { previewError != nil }, set: { if !$0 { previewError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(previewError ?? "Please try again.") }
    }

    private func scanRow(_ scan: SavedScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            if scan.hasScene {
                Button { openMap(scan) } label: {
                    if busyID == scan.id { ProgressView("Opening map…") }
                    else { Label("View map", systemImage: "map") }
                }
                .disabled(busyID != nil)
            } else {
                Text("Original scan saved. No finished map is available.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if scan.hasStream {
                Button { evidenceScanID = scan.id } label: {
                    Label("View scan data", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            if scan.hasVideo {
                if videoExportID == scan.id, let videoExportURL {
                    ShareLink(item: videoExportURL) {
                        Label("Share video + LiDAR", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button { exportVideo(scan) } label: {
                        if busyID == scan.id { ProgressView("Preparing export…") }
                        else { Label("Export video + LiDAR", systemImage: "video") }
                    }
                    .disabled(busyID != nil)
                }
            }
            if !scan.originalFiles.isEmpty {
                ShareLink(items: scan.originalFiles) {
                    Label("Export original scan", systemImage: "square.and.arrow.up")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }

    private func openMap(_ scan: SavedScan) {
        guard busyID == nil else { return }
        busyID = scan.id
        previewTask = Task {
            defer { busyID = nil; previewTask = nil }
            do {
                let scene = try await ScanWork.run { try Self.loadScene(scan) }
                try Task.checkCancellation()
                preview = SavedPreview(id: scan.id, scene: scene, hasStream: scan.hasStream)
            } catch is CancellationError {
                // Closing the list cancels its local reads.
            } catch {
                errorTitle = "Couldn't open the map"
                previewError = "The saved map couldn't be read. Your original scan data is still available."
            }
        }
    }

    private func exportVideo(_ scan: SavedScan) {
        guard busyID == nil else { return }
        busyID = scan.id
        let folder = FileManager.default.temporaryDirectory.appending(path: "inview-video-export-\(UUID().uuidString)")
        previewTask = Task {
            var completed = false
            defer {
                busyID = nil
                previewTask = nil
                if !completed { try? FileManager.default.removeItem(at: folder) }
            }
            do {
                let output = try await ScanWork.run(priority: .utility) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    let output = folder.appending(path: "\(scan.id).inviewvideo.tar")
                    try ScanVideoExport.write(captureDirectory: scan.root, to: output)
                    return output
                }
                try Task.checkCancellation()
                if let previous = videoExportURL {
                    try? FileManager.default.removeItem(at: previous.deletingLastPathComponent())
                }
                videoExportID = scan.id
                videoExportURL = output
                completed = true
            } catch is CancellationError {
                // Closing the list cancels the streamed export and removes its partial file.
            } catch {
                errorTitle = "Couldn't export video"
                previewError = "The video export couldn't be prepared. \(error.localizedDescription)"
            }
        }
    }

    private nonisolated static func loadScene(_ scan: SavedScan) throws -> ProcessedScene {
        try Task.checkCancellation()
        let sceneURL = scan.root.appending(path: "scene.json")
        if FileManager.default.fileExists(atPath: sceneURL.path) {
            let scene = try JSONDecoder().decode(ProcessedScene.self, from: Data(contentsOf: sceneURL))
            let captureURL = scan.root.appending(path: "capture.json")
            let source: CaptureBundle?
            if FileManager.default.fileExists(atPath: captureURL.path) {
                source = try JSONDecoder().decode(CaptureBundle.self, from: Data(contentsOf: captureURL))
                try source?.validate()
            } else {
                source = nil
            }
            try scene.validate(expectedScanID: scan.id, source: source)
            return scene
        }
        let resultURL = scan.root.appending(path: "stream/result.json")
        let result = try JSONDecoder().decode(StreamResult.self, from: Data(contentsOf: resultURL))
        try result.validate(streamID: scan.id)
        return result.scene
    }

    private nonisolated static func savedScans() throws -> [SavedScan] {
        let root = URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory)
        let files = FileManager.default
        guard files.fileExists(atPath: root.path) else { return [] }
        var scans: [SavedScan] = []
        for directory in try files.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) {
            try Task.checkCancellation()
            let id = directory.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            var originalFiles = ["roomplan.json", "roomplan-structure.json", "raw-snapshot.json", "capture.json"]
                .map { directory.appending(path: $0) }
                .filter { files.fileExists(atPath: $0.path) }
            for name in ["roomplan-source", "roomplan-rooms"] {
                let roomSources = directory.appending(path: name, directoryHint: .isDirectory)
                if let sourceValues = try? roomSources.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                   sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true,
                   let sources = try? files.contentsOfDirectory(at: roomSources,
                       includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                    for source in sources.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        try Task.checkCancellation()
                        guard ["json", "plist"].contains(source.pathExtension.lowercased()),
                              let sourceValues = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                              sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else { continue }
                        originalFiles.append(source)
                    }
                }
            }
            let hasStream = files.fileExists(atPath: directory.appending(path: "stream/manifest.json").path)
            let videoURL = directory.appending(path: "video-manifest.json")
            let hasVideo = (try? Data(contentsOf: videoURL)).flatMap {
                try? JSONDecoder().decode(ScanVideoManifest.self, from: $0)
            }.map { manifest in
                manifest.captureID == id && manifest.status != "recording" && !manifest.segments.isEmpty
                    && (try? manifest.validate()) != nil
            } ?? false
            let hasScene = files.fileExists(atPath: directory.appending(path: "scene.json").path)
                || files.fileExists(atPath: directory.appending(path: "stream/result.json").path)
            guard !originalFiles.isEmpty || hasStream || hasScene else { continue }
            scans.append(SavedScan(id: id, root: directory, date: values.creationDate ?? .distantPast,
                                   hasScene: hasScene, hasStream: hasStream, hasVideo: hasVideo, originalFiles: originalFiles))
        }
        return scans.sorted { $0.date > $1.date }
    }
}
