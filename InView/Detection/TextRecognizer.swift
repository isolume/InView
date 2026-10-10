import AccessCore
import Foundation
import ImageIO
import NaturalLanguage
import Vision

/// Reads signs and labels in a finished capture's upright images with Apple Vision, producing
/// `text-observations.json` for the backend to place in the map. Optional evidence: work is bounded
/// in images and time, never runs on the main thread, and any failure yields fewer observations.
enum TextRecognizer {
    /// One upright JPEG paired with the depth frame whose pose and intrinsics describe it.
    struct Image: Sendable {
        var frameID: String
        var asset: String
        /// The encoded bytes, or nil to read `url` lazily.
        var jpeg: Data?
        var url: URL?
    }

    struct Limits: Sendable {
        var maximumImages = 48
        var timeBudget: TimeInterval = 12
        static let standard = Limits()
    }

    /// High-resolution stills (`<frame-id>.ocr.jpg`) come first: they were taken for reading text.
    /// Then the capture's color keyframes.
    static func images(keyframes: [RawColorKeyframe], captureDirectory: URL?) -> [Image] {
        var stills: [Image] = []
        if let captureDirectory,
           let files = try? FileManager.default.contentsOfDirectory(
               at: captureDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
           ) {
            let suffix = ".ocr.jpg"
            stills = files.map(\.lastPathComponent).filter { $0.hasSuffix(suffix) && $0.count > suffix.count }.sorted()
                .map { Image(frameID: String($0.dropLast(suffix.count)), asset: $0, jpeg: nil,
                             url: captureDirectory.appending(path: $0)) }
        }
        let colors = keyframes.map { Image(frameID: $0.frameID, asset: $0.filename, jpeg: $0.jpeg, url: nil) }
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
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Skip text too small to be a readable sign at keyframe resolution.
        request.minimumTextHeight = 0.015
        // Capture images are encoded upright, so Vision sees them as the volunteer did.
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
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
            return CaptureTextObservation.make(
                frameID: image.frameID, imageAsset: image.asset, imageWidth: cgImage.width, imageHeight: cgImage.height,
                text: candidate.string, confidence: candidate.confidence,
                visionBox: (x: box.origin.x, y: box.origin.y, width: box.width, height: box.height),
                languages: languages(of: candidate.string)
            )
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
