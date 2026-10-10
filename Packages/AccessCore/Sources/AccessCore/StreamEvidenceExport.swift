import Foundation

/// A local reconstruction export of the saved portable stream, independent of upload state.
public enum StreamEvidenceExport {
    /// Publishes a complete TAR without replacing an existing file or modifying source evidence.
    /// The archive is read one validated chunk at a time; its preview sampling budget is irrelevant.
    public static func write(archive: StreamEvidenceArchive, to destination: URL) throws {
        try Task.checkCancellation()
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else {
            throw StreamEvidenceExportError.invalidDestination
        }
        let source = archive.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let output = parent.appendingPathComponent(destination.lastPathComponent)
        let sourceParts = source.pathComponents
        guard !output.standardizedFileURL.pathComponents.starts(with: sourceParts) else {
            throw StreamEvidenceExportError.invalidDestination
        }
        let files = FileManager.default
        guard !files.fileExists(atPath: output.path) else { throw StreamEvidenceExportError.destinationExists }
        let temporary = parent.appendingPathComponent(".inview-export-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: temporary) }
        let tarURL = temporary.appendingPathComponent("evidence.tar")
        let observationsURL = temporary.appendingPathComponent("observations.jsonl")
        let writer = try EvidenceTarWriter(url: tarURL)
        defer { writer.closeIgnoringErrors() }
        let observations = try Self.createFile(observationsURL)
        defer { try? observations.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var observationBytes: UInt64 = 0

        for sequence in 0..<archive.frameCount {
            try autoreleasepool {
                try Task.checkCancellation()
                let chunk = try archive.readChunk(sequence: sequence)
                let number = String(sequence)
                let stem = "frames/" + String(repeating: "0", count: max(0, 10 - number.count)) + number
                let rgb = EvidenceAsset(path: stem + ".jpg", role: "rgb_keyframe", mediaType: "image/jpeg",
                                        bytes: UInt64(chunk.colorJPEG.count))
                try writer.append(chunk.colorJPEG, path: rgb.path)
                let depthBytes = try Self.packDepth(chunk.frame.depth.valuesM)
                let depth = EvidenceAsset(path: stem + ".depth-f32le", role: "packed_portable_depth",
                                          mediaType: "application/octet-stream", bytes: UInt64(depthBytes.count))
                try writer.append(depthBytes, path: depth.path)
                var confidence: EvidenceAsset?
                if let values = chunk.frame.depth.confidence {
                    try Task.checkCancellation()
                    let bytes = Data(values.map(UInt8.init))
                    let asset = EvidenceAsset(path: stem + ".confidence-u8", role: "depth_confidence",
                                              mediaType: "application/octet-stream", bytes: UInt64(bytes.count))
                    try writer.append(bytes, path: asset.path)
                    confidence = asset
                }
                let record = EvidenceObservation(sequence: sequence, frame: chunk.frame, rgb: rgb, depth: depth,
                                                 confidence: confidence, objects: chunk.objects, surfaces: chunk.surfaces)
                var line = try encoder.encode(record)
                line.append(0x0a)
                try observations.write(contentsOf: line)
                let sum = observationBytes.addingReportingOverflow(UInt64(line.count))
                guard !sum.overflow else { throw StreamingCaptureError.storageFailure }
                observationBytes = sum.partialValue
            }
        }
        try observations.close()
        try writer.append(file: observationsURL, path: "observations.jsonl", bytes: observationBytes)
        let index = EvidenceAsset(path: "observations.jsonl", role: "calibrated_observation_index",
                                  mediaType: "application/x-ndjson", bytes: observationBytes)
        let manifest = EvidenceExportManifest(source: archive.manifest, frameCount: archive.frameCount, observations: index)
        try writer.append(encoder.encode(manifest), path: "manifest.json")
        try writer.finish()
        try Task.checkCancellation()
        // A hard link on the same filesystem publishes all bytes atomically and refuses to
        // replace even a destination created after the initial existence check.
        do { try files.linkItem(at: tarURL, to: output) }
        catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw StreamEvidenceExportError.destinationExists
        }
    }

    private static func createFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StreamingCaptureError.storageFailure
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func packDepth(_ values: [Float?]) throws -> Data {
        var data = Data(count: values.count * 4)
        try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (index, value) in values.enumerated() {
                if index.isMultiple(of: 1024) { try Task.checkCancellation() }
                // Nil is a canonical quiet NaN, never a measured zero or a fabricated distance.
                let bits = (value?.bitPattern ?? UInt32(0x7fc00000)).littleEndian
                bytes.storeBytes(of: bits, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        return data
    }
}

public enum StreamEvidenceExportError: Error, LocalizedError, Equatable {
    case invalidDestination, destinationExists

    public var errorDescription: String? {
        switch self {
        case .invalidDestination: return "Choose a file outside the saved scan folder."
        case .destinationExists: return "A file already exists at this location."
        }
    }
}

private struct EvidenceAsset: Encodable {
    var path: String
    var role: String
    var mediaType: String
    var bytes: UInt64
    enum CodingKeys: String, CodingKey { case path, role, mediaType = "media_type", bytes }
}

private struct EvidenceExportManifest: Encodable {
    let schemaVersion = 1
    let format = "inview_stream_evidence"
    var source: StreamManifest
    var frameCount: Int
    var observations: EvidenceAsset
    let assetIndex = "Each observations.jsonl record indexes its RGB, packed depth, and optional confidence assets with exact byte lengths."
    let coordinateFrame = "original_shared_arkit_session"
    let matrixLayout = "column_major"
    let pixelAlignment = "sensor_native; depth and RGB use the same normalized image coordinates; intrinsics describe the saved JPEG"
    let depthEncoding = "row_packed_little_endian_float32_meters; nil=quiet_NaN_0x7fc00000"
    let depthProvenance = "Saved portable depth values, not byte-exact native ARKit buffers. Original row padding and discarded invalid samples are unavailable."
    let confidenceEncoding = "row_packed_uint8; 0=low, 1=medium, 2=high"
    let labels = "Per-observation object and surface deltas in the original capture coordinates; retain their frame association."
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", format, source, frameCount = "frame_count", observations
        case assetIndex = "asset_index", coordinateFrame = "coordinate_frame", matrixLayout = "matrix_layout"
        case pixelAlignment = "pixel_alignment", depthEncoding = "depth_encoding", depthProvenance = "depth_provenance"
        case confidenceEncoding = "confidence_encoding", labels
    }
}

private struct EvidenceObservation: Encodable {
    var sequence: Int
    var frame: CaptureDepthFrame
    var rgb: EvidenceAsset
    var depth: EvidenceAsset
    var confidence: EvidenceAsset?
    var objects: [CaptureObject]
    var surfaces: [CaptureSurface]

    private enum CodingKeys: String, CodingKey {
        case sequence, id, timestampSeconds = "timestamp_seconds", pixelOrientation = "pixel_orientation"
        case mapFromCamera = "map_from_camera", camera, depth, rgb, confidence, objects, surfaces
    }
    private enum DepthKeys: String, CodingKey { case asset, width, height, bytesPerRow = "bytes_per_row" }
    private enum ConfidenceKeys: String, CodingKey { case asset, bytesPerRow = "bytes_per_row" }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(frame.id, forKey: .id)
        try container.encode(frame.timestampSeconds, forKey: .timestampSeconds)
        try container.encode(frame.pixelOrientation, forKey: .pixelOrientation)
        try container.encode(frame.mapFromCamera, forKey: .mapFromCamera)
        try container.encode(frame.camera, forKey: .camera)
        try container.encode(rgb, forKey: .rgb)
        var depthContainer = container.nestedContainer(keyedBy: DepthKeys.self, forKey: .depth)
        try depthContainer.encode(depth, forKey: .asset)
        try depthContainer.encode(frame.depth.width, forKey: .width)
        try depthContainer.encode(frame.depth.height, forKey: .height)
        try depthContainer.encode(frame.depth.width * 4, forKey: .bytesPerRow)
        if let confidence {
            var confidenceContainer = container.nestedContainer(keyedBy: ConfidenceKeys.self, forKey: .confidence)
            try confidenceContainer.encode(confidence, forKey: .asset)
            try confidenceContainer.encode(frame.depth.width, forKey: .bytesPerRow)
        }
        try container.encode(objects, forKey: .objects)
        try container.encode(surfaces, forKey: .surfaces)
    }
}

/// Safe generated paths, ordinary USTAR entries, and a PAX size extension for very large indexes.
/// The writer has no aggregate scene-size limit and never retains the whole TAR in memory.
private final class EvidenceTarWriter {
    private let handle: FileHandle
    private var closed = false
    private let block = 512
    private let maximumOctalSize: UInt64 = 0o77777777777

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StreamingCaptureError.storageFailure
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data, path: String) throws {
        try Task.checkCancellation()
        try begin(path: path, bytes: UInt64(data.count))
        try handle.write(contentsOf: data)
        try pad(bytes: UInt64(data.count))
    }

    func append(file: URL, path: String, bytes: UInt64) throws {
        try begin(path: path, bytes: bytes)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try input.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !data.isEmpty else { throw StreamingCaptureError.storageFailure }
            try handle.write(contentsOf: data)
            remaining -= UInt64(data.count)
        }
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else { throw StreamingCaptureError.storageFailure }
        try pad(bytes: bytes)
    }

    func finish() throws {
        try Task.checkCancellation()
        try handle.write(contentsOf: Data(repeating: 0, count: block * 2))
        try handle.synchronize()
        try handle.close()
        closed = true
    }

    func closeIgnoringErrors() {
        guard !closed else { return }
        try? handle.close()
        closed = true
    }

    private func begin(path: String, bytes: UInt64) throws {
        try Task.checkCancellation()
        if bytes > maximumOctalSize {
            // POSIX PAX avoids an arbitrary 8 GiB cutoff imposed by the USTAR size field.
            let payload = "size=\(bytes)\n"
            var length = payload.utf8.count + 2
            while true {
                let adjusted = String(length).utf8.count + 1 + payload.utf8.count
                if adjusted == length { break }
                length = adjusted
            }
            let record = Data("\(length) \(payload)".utf8)
            try handle.write(contentsOf: try header(path: "PaxHeader", bytes: UInt64(record.count), type: 0x78))
            try handle.write(contentsOf: record)
            try pad(bytes: UInt64(record.count))
        }
        try handle.write(contentsOf: try header(path: path, bytes: bytes > maximumOctalSize ? 0 : bytes, type: 0x30))
    }

    private func pad(bytes: UInt64) throws {
        let remaining = Int((UInt64(block) - bytes % UInt64(block)) % UInt64(block))
        if remaining > 0 { try handle.write(contentsOf: Data(repeating: 0, count: remaining)) }
    }

    private func header(path: String, bytes: UInt64, type: UInt8) throws -> Data {
        let pathBytes = Array(path.utf8)
        guard !pathBytes.isEmpty, pathBytes.count <= 100, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(".."), !pathBytes.contains(0) else {
            throw StreamingCaptureError.storageFailure
        }
        var header = [UInt8](repeating: 0, count: block)
        func text(_ value: String, at offset: Int, width: Int) {
            let bytes = Array(value.utf8)
            header.replaceSubrange(offset..<(offset + min(width, bytes.count)), with: bytes.prefix(width))
        }
        func octal(_ value: UInt64, at offset: Int, width: Int) {
            let value = String(value, radix: 8)
            text(String(repeating: "0", count: width - value.count - 1) + value + "\0", at: offset, width: width)
        }
        text(path, at: 0, width: 100)
        octal(0o600, at: 100, width: 8)
        octal(0, at: 108, width: 8)
        octal(0, at: 116, width: 8)
        octal(bytes, at: 124, width: 12)
        octal(0, at: 136, width: 12)
        for index in 148..<156 { header[index] = 0x20 }
        header[156] = type
        text("ustar\0", at: 257, width: 6)
        text("00", at: 263, width: 2)
        let checksum = header.reduce(UInt64.zero) { $0 + UInt64($1) }
        let checksumText = String(checksum, radix: 8)
        text(String(repeating: "0", count: 6 - checksumText.count) + checksumText + "\0 ", at: 148, width: 8)
        return Data(header)
    }
}
