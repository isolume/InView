import Foundation
import UniformTypeIdentifiers

/// Finds the trained Gaussian splat for the saved map: one imported in the app, or one copied into the scan's
/// `splat` folder next to the photos it was trained from.
enum SplatStore {
    /// The formats MetalSplatter reads: 3DGS `.ply`, antimatter15 `.splat`, and Niantic `.spz`.
    static let fileExtensions = ["ply", "splat", "spz"]
    /// For the file picker; extensions the system doesn't know fall back to any data file.
    static var contentTypes: [UTType] {
        let known = fileExtensions.compactMap { UTType(filenameExtension: $0) }
        return known.count == fileExtensions.count ? known : known + [.data]
    }

    /// The LiDAR points saved to start training from: a point cloud, not a splat.
    private static let startingPoints = "sparse_pc.ply"

    static func find() -> URL? {
        if let imported = importedURL { return imported }
        guard let bundle = CaptureStore.loadSavedBundle(),
              let directory = try? CaptureStore.splatDirectory(for: bundle.id),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        // The newest splat wins, so retraining and copying back replaces the old one.
        return files
            .filter { fileExtensions.contains($0.pathExtension.lowercased()) && $0.lastPathComponent != startingPoints }
            .max { modified($0) < modified($1) }
    }

    /// Copies a splat into the app's Documents, replacing any imported before.
    static func importSplat(from source: URL) throws -> URL {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let destination = URL.documentsDirectory.appending(path: "venue-splat.\(source.pathExtension.lowercased())")
        let staged = URL.temporaryDirectory.appending(path: UUID().uuidString + "." + destination.pathExtension)
        try FileManager.default.copyItem(at: source, to: staged)
        removeImported()
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }

    static func removeImported() {
        for url in importedCandidates { try? FileManager.default.removeItem(at: url) }
    }

    private static var importedURL: URL? {
        importedCandidates.first { FileManager.default.fileExists(atPath: $0.path()) }
    }

    private static var importedCandidates: [URL] {
        fileExtensions.map { URL.documentsDirectory.appending(path: "venue-splat.\($0)") }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
