import Foundation
import ImageIO

/// A continuous capture keeps one world coordinate system for its entire lifetime.
public struct StreamManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var mapID: String
    public var floorID: String
    public var coordinates: CaptureCoordinates

    public init(schemaVersion: Int = 1, id: String, mapID: String, floorID: String = "ground",
                coordinates: CaptureCoordinates = .metersYUpRightHanded) {
        self.schemaVersion = schemaVersion; self.id = id; self.mapID = mapID
        self.floorID = floorID; self.coordinates = coordinates
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", id, mapID = "map_id", floorID = "floor_id", coordinates
    }

    public func validate() throws {
        guard schemaVersion == 1, UUID(uuidString: id) != nil,
              Self.safeIdentifier(mapID), Self.safeIdentifier(floorID),
              coordinates == .metersYUpRightHanded else {
            throw StreamingCaptureError.invalidManifest
        }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// The RGB image and depth observation were captured together, in sensor-native orientation.
/// Calibration describes the encoded JPEG; depth uses the same normalized image coordinates.
public struct StreamChunk: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 4 * 1024 * 1024
    public static let maximumColorBytes = 512 * 1024
    public static let maximumColorPixels = 1024 * 1024
    public static let maximumDepthSamples = 512 * 512
    public var sequence: Int
    public var frame: CaptureDepthFrame
    public var colorJPEG: Data
    public var surfaces: [CaptureSurface]
    public var objects: [CaptureObject]
    /// Geographic/building context at this frame (GPS, heading, barometer). Optional evidence.
    public var environment: CaptureEnvironmentSample?
    /// Dense camera poses recorded since the previous chunk: the walk between keyframes.
    public var poses: [StreamPose]

    public static let maximumPoses = 600

    public init(sequence: Int, frame: CaptureDepthFrame, colorJPEG: Data,
                surfaces: [CaptureSurface] = [], objects: [CaptureObject] = [],
                environment: CaptureEnvironmentSample? = nil, poses: [StreamPose] = []) {
        self.sequence = sequence; self.frame = frame; self.colorJPEG = colorJPEG
        self.surfaces = surfaces; self.objects = objects
        self.environment = environment; self.poses = poses
    }

    enum CodingKeys: String, CodingKey {
        case sequence, frame, colorJPEG = "color_jpeg", surfaces, objects, environment, poses
    }

    /// Older servers reject unknown keys, so empty context is omitted rather than sent as `[]`/`null`.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(frame, forKey: .frame)
        try values.encode(colorJPEG, forKey: .colorJPEG)
        try values.encode(surfaces, forKey: .surfaces)
        try values.encode(objects, forKey: .objects)
        try values.encodeIfPresent(environment, forKey: .environment)
        if !poses.isEmpty { try values.encode(poses, forKey: .poses) }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try values.decode(Int.self, forKey: .sequence)
        frame = try values.decode(CaptureDepthFrame.self, forKey: .frame)
        colorJPEG = try values.decode(Data.self, forKey: .colorJPEG)
        surfaces = try values.decodeIfPresent([CaptureSurface].self, forKey: .surfaces) ?? []
        objects = try values.decodeIfPresent([CaptureObject].self, forKey: .objects) ?? []
        environment = try values.decodeIfPresent(CaptureEnvironmentSample.self, forKey: .environment)
        poses = try values.decodeIfPresent([StreamPose].self, forKey: .poses) ?? []
    }

    public func validate() throws {
        let pixels = frame.camera.imageWidth.multipliedReportingOverflow(by: frame.camera.imageHeight)
        guard sequence >= 0, !colorJPEG.isEmpty, colorJPEG.count <= Self.maximumColorBytes,
              colorJPEG.starts(with: [0xff, 0xd8]), colorJPEG.suffix(2).elementsEqual([0xff, 0xd9]),
              frame.camera.imageWidth <= 2048, frame.camera.imageHeight <= 2048,
              !pixels.overflow, pixels.partialValue <= Self.maximumColorPixels,
              frame.depth.valuesM.count <= Self.maximumDepthSamples,
              frame.depth.confidence != nil,
              surfaces.count <= 1024, objects.count <= 1024,
              poses.count <= Self.maximumPoses, poses.allSatisfy(\.isValid),
              environment?.isFinite ?? true else {
            throw StreamingCaptureError.invalidChunk
        }
        let observation = CaptureBundle(id: "stream", mapID: "stream", frames: [frame],
                                        objects: objects, surfaces: surfaces)
        do { try observation.validate() }
        catch { throw StreamingCaptureError.invalidChunk }
        guard let source = CGImageSourceCreateWithData(colorJPEG as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == frame.camera.imageWidth, height == frame.camera.imageHeight,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw StreamingCaptureError.invalidChunk
        }
    }

    /// Sorted keys make retries byte-identical while preserving ordinary base64 Data encoding.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(self) }
        catch { throw StreamingCaptureError.invalidChunk }
        guard data.count <= Self.maximumEncodedBytes else { throw StreamingCaptureError.chunkTooLarge }
        return data
    }
}

public struct StreamSummary: Codable, Equatable, Sendable {
    public var id: String
    public var mapID: String
    public var floorID: String
    public var nextSequence: Int
    public var finished: Bool
    public var frameCount: Int

    public init(id: String, mapID: String, floorID: String, nextSequence: Int,
                finished: Bool, frameCount: Int) {
        self.id = id; self.mapID = mapID; self.floorID = floorID
        self.nextSequence = nextSequence; self.finished = finished; self.frameCount = frameCount
    }

    enum CodingKeys: String, CodingKey {
        case id, mapID = "map_id", floorID = "floor_id", nextSequence = "next_sequence"
        case finished, frameCount = "frame_count"
    }

    public func validate(manifest: StreamManifest) throws {
        guard id == manifest.id, mapID == manifest.mapID, floorID == manifest.floorID,
              nextSequence >= 0, frameCount == nextSequence else {
            throw BackendClientError.invalidResponse("The scan server acknowledged a different scan.")
        }
    }
}

public struct StreamResult: Codable, Equatable, Sendable {
    public var capture: CaptureBundle
    public var scene: ProcessedScene
    public var alignment: StreamAlignment?
    public init(capture: CaptureBundle, scene: ProcessedScene, alignment: StreamAlignment? = nil) {
        self.capture = capture; self.scene = scene; self.alignment = alignment
    }

    public func validate(streamID: String) throws {
        guard capture.id == streamID else {
            throw BackendClientError.invalidResponse("The scan server returned a different scan.")
        }
        do {
            try capture.validate()
            try scene.validate(expectedScanID: streamID, source: capture)
        } catch { throw BackendClientError.invalidResponse(error.localizedDescription) }
        try alignment?.validate()
        if case .object(let metadata) = capture.metadata {
            for key in ["alignment_optimized", "alignment_refined"] {
                guard let value = metadata[key] else { continue }
                guard case .bool(let optimized) = value, optimized == (alignment?.optimized ?? false) else {
                    throw StreamAlignment.invalidResponse
                }
            }
        }
    }

    public func validate(manifest: StreamManifest) throws {
        guard capture.mapID == manifest.mapID, capture.floorID == manifest.floorID,
              capture.coordinates == manifest.coordinates else {
            throw BackendClientError.invalidResponse("The scan server returned a different scan.")
        }
        try validate(streamID: manifest.id)
    }
}

public enum StreamingCaptureError: Error, LocalizedError, Equatable {
    case invalidManifest, invalidChunk, chunkTooLarge, storageFailure, localConflict
    case missingChunks, backendChanged, notConfigured, captureClosed, serverAhead, emptyCapture, queueBusy
    case captureLimit, invalidLimits

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "This scan needs valid map and floor identifiers."
        case .invalidChunk: return "This frame could not be prepared for the scan."
        case .chunkTooLarge: return "This frame is too large to send. Reduce the capture resolution."
        case .storageFailure: return "The scan could not be saved on this device. Check available storage."
        case .localConflict: return "A different scan already uses this saved folder."
        case .missingChunks: return "Part of this saved scan is missing. Its remaining frames have been kept."
        case .backendChanged: return "This saved scan belongs to a different scan server."
        case .notConfigured: return "Choose a scan server to send this saved scan."
        case .captureClosed: return "This scan has already ended. Start a new scan to add more frames."
        case .serverAhead: return "The scan server has frames that are missing from this device."
        case .emptyCapture: return "Capture some of the space before finishing the scan."
        case .queueBusy: return "Wait for the current upload before changing the scan server."
        case .captureLimit: return "This scan has reached its limit. Finish it before starting another scan."
        case .invalidLimits: return "This scan has an invalid capture limit."
        }
    }
}
