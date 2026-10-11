import AccessCore
import Foundation
import ImageIO
import NaturalLanguage
import Vision

/// Reads signs and labels in a finished capture's upright images with Apple Vision, producing
/// `text-observations.json` for the backend to place in the map. Optional evidence: work is bounded
/// in images and time, never runs on the main thread, and any failure yields fewer observations.
enum TextRecognizer {
    struct Calibration: Sendable {
        var frame: CaptureDepthFrame
        var floorID: String?
        var floorY: Float?
        var environment: CaptureEnvironmentSample?
        var reference: BuildingMapReference? = nil
    }
    /// One upright JPEG paired with the depth frame whose pose and intrinsics describe it.
    struct Image: Sendable {
        var frameID: String
        var asset: String
        /// The encoded bytes, or nil to read `url` lazily.
        var jpeg: Data?
        var url: URL?
        var sensorNative = false
        var calibration: Calibration? = nil
    }

    struct Limits: Sendable {
        var maximumImages = 48
        var timeBudget: TimeInterval = 12
        static let standard = Limits()
    }

    /// A posed color image from any capture path (streamed keyframe, still, or saved photo).
    struct Source: Sendable {
        var frameID: String
        var filename: String
        var jpeg: Data
        /// Streamed keyframes are encoded sensor-native (landscape). Vision reads them rotated
        /// upright and reports boxes in that upright image, the package's keyframe convention.
        var sensorNative = false
        var calibration: Calibration? = nil
    }

    /// High-resolution stills (`<frame-id>.ocr.jpg`) come first: they were taken for reading text.
    /// Then the capture's color keyframes.
    static func images(keyframes: [Source], captureDirectory: URL?) -> [Image] {
        let calibrations = Dictionary(keyframes.compactMap { source in source.calibration.map { (source.frameID, $0) } },
                                      uniquingKeysWith: { first, _ in first })
        var stills: [Image] = []
        if let captureDirectory,
           let files = try? FileManager.default.contentsOfDirectory(
               at: captureDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
           ) {
            let suffix = ".ocr.jpg"
            stills = files.map(\.lastPathComponent).filter { $0.hasSuffix(suffix) && $0.count > suffix.count }.sorted()
                .map { Image(frameID: String($0.dropLast(suffix.count)), asset: $0, jpeg: nil,
                             url: captureDirectory.appending(path: $0),
                             calibration: calibrations[String($0.dropLast(suffix.count))]) }
        }
        let colors = keyframes.map {
            Image(frameID: $0.frameID, asset: $0.filename, jpeg: $0.jpeg, url: nil, sensorNative: $0.sensorNative,
                  calibration: $0.calibration)
        }
        return stills + colors
    }

    /// Recognizes text in up to `limits.maximumImages` images, stopping when the time budget runs out
    /// or the task is cancelled. Call from a background task.
    static func recognize(_ images: [Image], limits: Limits = .standard) -> TextObservationsDocument {
        let deadline = Date.now.addingTimeInterval(limits.timeBudget)
        var observations: [CaptureTextObservation] = []
        var processed = 0
        for image in images.prefix(limits.maximumImages) {
            guard Date.now < deadline, !Task.isCancelled else { break }
            observations += recognize(image, deadline: deadline)
            processed += 1
        }
        Log.scan.notice("text recognition read \(observations.count) lines in \(processed) of \(images.count) images")
        return TextObservationsDocument(observations: CaptureTextObservation.sorted(observations))
    }

    private static func recognize(_ image: Image, deadline: Date) -> [CaptureTextObservation] {
        guard let data = image.jpeg ?? image.url.flatMap({ try? Data(contentsOf: $0) }),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Room identifiers must not be autocorrected into dictionary words.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        // Skip text too small to be a readable sign at keyframe resolution.
        request.minimumTextHeight = 0.015
        // Keyframes and stills are upright; streamed frames are sensor-native and rotated right.
        // With `.right`, Vision's normalized boxes refer to the upright image (width and height swap).
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.sensorNative ? .right : .up)
        let (uprightWidth, uprightHeight) = image.sensorNative ? (cgImage.height, cgImage.width) : (cgImage.width, cgImage.height)
        // A single slow request must not outlive the budget: cancel it from outside when time runs out.
        // (Task cancellation is checked between images.)
        let watchdog = DispatchWorkItem { request.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: watchdog)
        defer { watchdog.cancel() }
        do {
            try handler.perform([request])
        } catch {
            Log.scan.notice("text recognition skipped \(image.asset, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        return (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first else { return nil }
            let box = result.boundingBox
            guard var observation = CaptureTextObservation.make(
                frameID: image.frameID, imageAsset: image.asset, imageWidth: uprightWidth, imageHeight: uprightHeight,
                text: candidate.string, confidence: candidate.confidence,
                visionBox: (x: box.origin.x, y: box.origin.y, width: box.width, height: box.height),
                languages: languages(of: candidate.string)
            ) else { return nil }
            if let calibration = image.calibration {
                observation.spatial = SignLocalizer.locate(observation, frame: calibration.frame,
                    floorID: calibration.floorID, floorY: calibration.floorY,
                    environment: calibration.environment, reference: calibration.reference)
            }
            return observation
        }
    }

    /// Vision doesn't report a per-line language, so guess it from the text. Short strings such as
    /// room numbers are left unlabeled rather than guessed.
    static func languages(of text: String) -> [String] {
        guard text.filter(\.isLetter).count >= 3 else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3)
            .filter { $0.value >= 0.2 }
            .sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map(\.key.rawValue)
    }
}
