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
    /// How the OCR'd image relates to the calibrated, sensor-native camera image of `frameID`
    /// (whose intrinsics are landscape). Always `CaptureImageOrientation.uprightRotatedRightFromSensor`
    /// for iPhone keyframes and stills: the upright image is the sensor image rotated 90° clockwise.
    public var imageOrientation: String
    public var text: String
    public var confidence: Double
    /// `[x, y, width, height]` normalized to the upright image, with a top-left origin and y down.
    public var bboxNorm: [Double]
    /// The same box in the sensor-native camera image (top-left origin, normalized), ready to be
    /// unprojected with the frame's intrinsics without knowing the upright image's orientation.
    public var bboxSensorNorm: [Double]
    /// BCP 47 language codes, most likely first; empty when the text is too short to tell.
    public var languages: [String]

    public init(frameID: String, imageAsset: String, imageSizePx: [Int], text: String, confidence: Double,
                bboxNorm: [Double], languages: [String],
                imageOrientation: String = CaptureImageOrientation.uprightRotatedRightFromSensor) {
        self.frameID = frameID
        self.imageAsset = imageAsset
        self.imageSizePx = imageSizePx
        self.imageOrientation = imageOrientation
        self.text = text
        self.confidence = confidence
        self.bboxNorm = bboxNorm
        self.bboxSensorNorm = CaptureImageOrientation.sensorBox(fromUpright: bboxNorm)
        self.languages = languages
    }

    enum CodingKeys: String, CodingKey {
        case frameID = "frame_id", imageAsset = "image_asset", imageSizePx = "image_size_px", text, confidence
        case imageOrientation = "image_orientation", bboxNorm = "bbox_norm", bboxSensorNorm = "bbox_sensor_norm", languages
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

/// Orientation of exported capture images relative to the calibrated sensor-native camera image.
public enum CaptureImageOrientation {
    /// `FrameEncoder` applies `.oriented(.right)`: the upright image is the landscape sensor image
    /// rotated 90° clockwise. Upright pixel (px, py) of a W×H image is sensor-normalized
    /// (u, v) = (py / H, 1 − px / W).
    public static let uprightRotatedRightFromSensor = "upright_rotated_right_from_sensor"

    /// Maps a normalized top-left `[x, y, w, h]` box in the upright image to the sensor image.
    public static func sensorBox(fromUpright box: [Double]) -> [Double] {
        guard box.count == 4 else { return box }
        let (x, y, w, h) = (box[0], box[1], box[2], box[3])
        return [y, 1 - x - w, h, w].map { ($0 * 1e6).rounded() / 1e6 }
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
