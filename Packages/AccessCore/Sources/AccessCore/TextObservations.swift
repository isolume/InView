import Foundation

/// `text-observations.json`: text the phone read in its capture images, for the backend to place
/// in the map with the matching frame's pose and depth. Pixels alone never establish map position.
public struct TextObservationsDocument: Codable, Equatable, Sendable {
    public static let filename = "text-observations.json"

    public var schemaVersion: Int
    public var engine: String
    public var observations: [CaptureTextObservation]

    public init(schemaVersion: Int = 1, engine: String = "apple_vision", observations: [CaptureTextObservation]) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.observations = observations
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", engine, observations
    }

    /// Stable, compact JSON: the same recognitions always produce the same bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct CaptureTextObservation: Codable, Equatable, Sendable {
    /// The calibrated depth frame the image belongs to.
    public var frameID: String
    /// The image file inside the capture package.
    public var imageAsset: String
    /// Width and height of that (upright) image in pixels.
    public var imageSizePx: [Int]
    public var text: String
    public var confidence: Double
    /// `[x, y, width, height]` normalized to the image, with a top-left origin and y down.
    public var bboxNorm: [Double]
    /// BCP 47 language codes, most likely first; empty when the text is too short to tell.
    public var languages: [String]

    public init(frameID: String, imageAsset: String, imageSizePx: [Int], text: String, confidence: Double,
                bboxNorm: [Double], languages: [String]) {
        self.frameID = frameID
        self.imageAsset = imageAsset
        self.imageSizePx = imageSizePx
        self.text = text
        self.confidence = confidence
        self.bboxNorm = bboxNorm
        self.languages = languages
    }

    enum CodingKeys: String, CodingKey {
        case frameID = "frame_id", imageAsset = "image_asset", imageSizePx = "image_size_px", text, confidence
        case bboxNorm = "bbox_norm", languages
    }

    /// Normalizes one recognition, or rejects it when it carries nothing usable.
    /// - Parameter visionBox: Vision's normalized `[x, y, width, height]` with a bottom-left origin.
    public static func make(
        frameID: String, imageAsset: String, imageWidth: Int, imageHeight: Int, text: String,
        confidence: Float, visionBox: (x: Double, y: Double, width: Double, height: Double),
        languages: [String], minimumConfidence: Float = TextObservationLimits.minimumConfidence
    ) -> CaptureTextObservation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !frameID.isEmpty, !imageAsset.isEmpty, imageWidth > 0, imageHeight > 0,
              confidence.isFinite, confidence >= minimumConfidence,
              let box = VisionGeometry.topLeftBox(visionBox) else { return nil }
        return CaptureTextObservation(
            frameID: frameID, imageAsset: imageAsset, imageSizePx: [imageWidth, imageHeight],
            text: String(trimmed.prefix(TextObservationLimits.maximumTextLength)),
            // Micro-normalized precision is far finer than a pixel and keeps the JSON free of float noise.
            confidence: Double(min(max(confidence, 0), 1)), bboxNorm: box.map { ($0 * 1e6).rounded() / 1e6 },
            languages: languages
        )
    }

    /// Image order first, then reading order (top to bottom, left to right) within an image.
    public static func sorted(_ observations: [CaptureTextObservation]) -> [CaptureTextObservation] {
        observations.sorted {
            ($0.imageAsset, $0.bboxNorm[1], $0.bboxNorm[0], $0.text) < ($1.imageAsset, $1.bboxNorm[1], $1.bboxNorm[0], $1.text)
        }
    }
}

public enum TextObservationLimits {
    public static let minimumConfidence: Float = 0.3
    public static let maximumTextLength = 256
}

public enum VisionGeometry {
    /// Converts Vision's normalized, bottom-left-origin rectangle into a top-left-origin one, clipped
    /// to the image. Returns nil for nonfinite or empty boxes.
    public static func topLeftBox(_ box: (x: Double, y: Double, width: Double, height: Double)) -> [Double]? {
        guard box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite else { return nil }
        let minX = max(0, min(1, box.x)), maxX = max(0, min(1, box.x + box.width))
        let minY = max(0, min(1, box.y)), maxY = max(0, min(1, box.y + box.height))
        guard maxX > minX, maxY > minY else { return nil }
        return [minX, 1 - maxY, maxX - minX, maxY - minY]
    }
}
