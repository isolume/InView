import Darwin
import Foundation

/// A local reconstruction handoff containing every finalized video/depth segment.
/// Large media are streamed from validated regular files, independently of upload limits.
public enum ScanVideoExport {
    public static func write(captureDirectory: URL, to destination: URL) throws {
        try Task.checkCancellation()
        guard captureDirectory.isFileURL, destination.isFileURL,
              !destination.lastPathComponent.isEmpty else {
            throw ScanVideoExportError.invalidDestination
        }
        let source = captureDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let output = parent.appendingPathComponent(destination.lastPathComponent)
        guard !output.standardizedFileURL.pathComponents.starts(with: source.pathComponents) else {
            throw ScanVideoExportError.invalidDestination
        }
        var existing = stat()
        if lstat(output.path, &existing) == 0 { throw ScanVideoExportError.destinationExists }
        guard errno == ENOENT else { throw ScanVideoExportError.invalidDestination }

        let directory = try VideoSourceDirectory(url: source)
        let manifestFile = try directory.requiredFile("video-manifest.json")
        let manifestData = try manifestFile.readJSON(maximumBytes: 4 * 1024 * 1024)
        let manifest = try JSONDecoder().decode(ScanVideoManifest.self, from: manifestData)
        try manifest.validate()
        guard manifest.status != "recording", !manifest.segments.isEmpty,
              manifest.status != "partial" || manifest.stopReason != nil else {
            throw ScanVideoExportError.unfinishedRecording
        }

        let captureFile = try directory.requiredFile("capture.json")
        // The capture is a JSON model rather than media; decoding needs its complete document.
        // There is no upload-size or aggregate scene-size budget for a local handoff.
        let captureData = try captureFile.readJSON()
        let capture = try JSONDecoder().decode(CaptureBundle.self, from: captureData)
        try capture.validate()
        guard capture.id == manifest.captureID, capture.mapID == manifest.mapID,
              capture.floorID == manifest.floorID, capture.coordinates == manifest.coordinates else {
            throw ScanVideoExportError.mismatchedCapture
        }

        var indexedFiles: [VideoSourceIdentity] = []
        for segment in manifest.segments {
            try Task.checkCancellation()
            let video = try directory.requiredFile(segment.videoAsset, bytes: UInt64(segment.videoBytes))
            indexedFiles.append(video.identity)
            let depth = try directory.requiredFile(segment.depthAsset, bytes: UInt64(segment.depthBytes))
            indexedFiles.append(depth.identity)
            let frames = try directory.requiredFile(segment.framesAsset, bytes: UInt64(segment.framesBytes))
            let frameData = try frames.readJSON(maximumBytes: 1024 * 1024)
            let document = try JSONDecoder().decode(ScanVideoFrameDocument.self, from: frameData)
            guard document.schemaVersion == manifest.schemaVersion else {
                throw ScanVideoExportError.invalidSource
            }
            try document.validate(segment: segment)
            indexedFiles.append(frames.identity)
        }
        for name in ["roomplan.json", "roomplan.plist", "roomplan-structure.json", "roomplan-structure.plist",
                     "camera-track.json", "semantics.json", "worldmap.archive"] {
            if let file = try directory.file(name) { indexedFiles.append(file.identity) }
        }

        let files = FileManager.default
        let temporary = parent.appendingPathComponent(".inview-video-export-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let tarURL = temporary.appendingPathComponent("scan-video.tar")
        let writer = try EvidenceTarWriter(url: tarURL)
        defer { writer.closeIgnoringErrors() }
        let prefix = manifest.captureID + "/"
        try writer.append(manifestData, path: prefix + manifestFile.identity.name)
        try writer.append(captureData, path: prefix + captureFile.identity.name)
        for identity in indexedFiles {
            try Task.checkCancellation()
            let file = try directory.requiredFile(identity.name, bytes: identity.bytes)
            try file.checkUnchanged(identity)
            try writer.append(input: file.handle, path: prefix + identity.name, bytes: identity.bytes)
            try file.checkUnchanged(identity)
        }
        try writer.append(Data(reconstructionReadme.utf8), path: prefix + "README.txt")
        try writer.finish()
        try Task.checkCancellation()
        // Same-filesystem hard-link publication is atomic and never replaces a competing file.
        do { try files.linkItem(at: tarURL, to: output) }
        catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw ScanVideoExportError.destinationExists
        }
    }

    private static let reconstructionReadme = """
    InView video + LiDAR reconstruction evidence

    video-manifest.json lists finalized segments and their exact asset sizes. A partial
    recording retains its completed segments and records its stop reason; skipped
    samples and gaps remain visible rather than being filled with invented evidence.
    capture.json contains the measured scan geometry in the same original, shared
    ARKit session coordinate frame: meters, Y up, right handed. map_from_camera
    matrices are column-major and map camera coordinates into that scan frame.
    ARKit camera coordinates use +X right, +Y up, and -Z forward.

    Each frames.json entry indexes one successfully encoded RGB frame with its pose
    and calibration. When present, raw_depth indexes depth copied from the same ARFrame
    as byte ranges in depth.bin. An absent raw_depth means that frame has no measured
    depth; its pose and camera calibration remain valid. Schema 2 permits these frames
    and an empty depth.bin when an entire segment has no measured depth. Schema 1
    requires recorded depth for every frame. Never invent depth for an absent entry.
    Little-endian Float32 depth is in meters, with native row stride and raw bits intact.
    Ignore row padding and nonfinite/invalid distances. Optional confidence is UInt8
    with its own row stride: 0 low, 1 medium, 2 high.

    The MP4 encodes sensor-native landscape pixels. Its playback track applies a
    90-degree clockwise display transform. For geometric projection, use decoded
    sensor-native pixels before that transform, or transform pixels and intrinsics
    together. sensor_camera describes the original sensor image; video_camera has
    intrinsics scaled to the encoded video resolution. Depth and RGB correspond in
    normalized sensor-native image coordinates.

    Match frames by presentation_time_seconds and timestamp_seconds, then use that
    entry's pose and calibration. Presentation time starts at zero per segment;
    ARKit timestamps share the scan's monotonic clock. unix_offset_seconds relates
    that clock to wall time. Do not infer pose from frame number or target FPS:
    dropped samples create variable timing and segment gaps.

    Keep generated or inferred geometry anchored to measured LiDAR meshes and
    RoomPlan dimensions, and check reprojection and metric scale. ARKit poses and
    LiDAR are estimates with drift and measurement error, not exact ground truth.
    A video or an LLM interpretation alone does not guarantee geometric accuracy.
    Optional RoomPlan, camera track, semantics, and native world-map files retain
    additional scan evidence. No remote inference has been performed by this export.
    """
}

public enum ScanVideoExportError: Error, LocalizedError, Equatable {
    case invalidDestination, destinationExists, invalidSource, unfinishedRecording, mismatchedCapture

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: return "Choose a file outside the saved scan folder."
        case .destinationExists: return "A file already exists at this location."
        case .invalidSource: return "Part of this saved scan video is missing, changed, or invalid."
        case .unfinishedRecording: return "Finish recording before exporting the saved scan video."
        case .mismatchedCapture: return "The saved video belongs to a different scan."
        }
    }
}

/// Relative opens pin the directory and refuse links, including dangling links and
/// files replaced between validation and export. Special files can never block reads.
private final class VideoSourceDirectory {
    private let handle: FileHandle

    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ScanVideoExportError.invalidSource }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func requiredFile(_ name: String, bytes: UInt64? = nil) throws -> VideoSourceFile {
        guard let file = try file(name, bytes: bytes) else { throw ScanVideoExportError.invalidSource }
        return file
    }

    func file(_ name: String, bytes: UInt64? = nil) throws -> VideoSourceFile? {
        try Task.checkCancellation()
        guard !name.isEmpty, name.utf8.count <= 64, !name.contains("/"), !name.contains("\\"),
              name != ".", name != "..", !name.utf8.contains(0) else {
            throw ScanVideoExportError.invalidSource
        }
        let descriptor = openat(handle.fileDescriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw ScanVideoExportError.invalidSource }
            return nil
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let identity = try VideoSourceIdentity(name: name, descriptor: descriptor)
        guard bytes == nil || bytes == identity.bytes else { throw ScanVideoExportError.invalidSource }
        return VideoSourceFile(handle: input, identity: identity)
    }
}

private struct VideoSourceIdentity: Equatable {
    let name: String
    let bytes: UInt64
    private let device: dev_t
    private let inode: ino_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    init(name: String, descriptor: Int32) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0 else { throw ScanVideoExportError.invalidSource }
        self.name = name; bytes = UInt64(information.st_size)
        device = information.st_dev; inode = information.st_ino
        modifiedSeconds = information.st_mtimespec.tv_sec
        modifiedNanoseconds = information.st_mtimespec.tv_nsec
        changedSeconds = information.st_ctimespec.tv_sec
        changedNanoseconds = information.st_ctimespec.tv_nsec
    }
}

private struct VideoSourceFile {
    let handle: FileHandle
    let identity: VideoSourceIdentity

    func checkUnchanged(_ expected: VideoSourceIdentity) throws {
        guard try VideoSourceIdentity(name: identity.name, descriptor: handle.fileDescriptor) == expected else {
            throw ScanVideoExportError.invalidSource
        }
    }

    func readJSON(maximumBytes: UInt64 = UInt64(Int.max)) throws -> Data {
        guard identity.bytes > 0, identity.bytes <= maximumBytes, identity.bytes <= UInt64(Int.max) else {
            throw ScanVideoExportError.invalidSource
        }
        var result = Data()
        var remaining = identity.bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !data.isEmpty else { throw ScanVideoExportError.invalidSource }
            result.append(data)
            remaining -= UInt64(data.count)
        }
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw ScanVideoExportError.invalidSource }
        try checkUnchanged(identity)
        return result
    }
}
