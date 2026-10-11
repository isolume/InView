import AVFoundation
import Speech

/// Push-to-talk transcription with Apple's speech recognizer. A question ends when the speaker pauses,
/// when `stop()` is called, or after a time limit.
@MainActor
final class SpeechListener {
    enum ListenError: LocalizedError {
        case speechDenied
        case microphoneDenied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .speechDenied: "Allow Speech Recognition for InView in Settings to ask questions by voice."
            case .microphoneDenied: "Allow microphone access for InView in Settings to ask questions by voice."
            case .unavailable: "Speech recognition isn’t available right now. Try typing your question."
            }
        }
    }

    /// A pause this long after speech ends the question.
    private static let pauseToFinish: Duration = .seconds(1.4)
    /// Give up if nothing is heard for this long.
    private static let waitForSpeech: Duration = .seconds(7)
    private static let maximumLength: Duration = .seconds(15)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var transcript = ""
    private var onPartial: ((String) -> Void)?
    private var completion: CheckedContinuation<String, Never>?

    var isListening: Bool { completion != nil }

    /// The transcript once the speaker finishes; empty if nothing was heard or listening was cancelled.
    /// `hints` bias recognition toward place names the speaker is likely to say.
    func listen(hints: [String], onPartial: @escaping (String) -> Void) async throws -> String {
        finish(with: "")
        try await Self.requestPermissions()
        guard let recognizer, recognizer.isAvailable else { throw ListenError.unavailable }
        try await Self.activateSession()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .search
        request.contextualStrings = Array(hints.prefix(100))
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenError.unavailable }
        Self.installTap(on: input, format: format, feeding: request)
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw ListenError.unavailable
        }

        self.request = request
        self.onPartial = onPartial
        transcript = ""
        return await withCheckedContinuation { continuation in
            completion = continuation
            task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self))
            restartTimer(after: Self.waitForSpeech)
            limit = Task { [weak self] in
                try? await Task.sleep(for: Self.maximumLength)
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        }
    }

    /// Ends the question now with what has been heard so far.
    func stop() {
        finish(with: transcript)
    }

    func cancel() {
        finish(with: "")
    }

    private func received(_ text: String?, isFinal: Bool, failed: Bool) {
        guard completion != nil else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            onPartial?(text)
            restartTimer(after: Self.pauseToFinish)
        }
        if isFinal || failed { stop() }
    }

    private func restartTimer(after delay: Duration) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func finish(with text: String) {
        timer?.cancel(); timer = nil
        limit?.cancel(); limit = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        onPartial = nil
        let completion = completion
        self.completion = nil
        completion?.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Built outside the main actor: the tap and the recognizer call back on their own threads.

    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               feeding request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func resultHandler(for listener: SpeechListener) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak listener] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in listener?.received(text, isFinal: isFinal, failed: error != nil) }
        }
    }

    nonisolated private static func requestPermissions() async throws {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { throw ListenError.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else { throw ListenError.microphoneDenied }
    }

    /// Shares VoiceGuide's queue, so this applies in order with its own session changes.
    nonisolated private static func activateSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            VoiceGuide.sessionQueue.async {
                let session = AVAudioSession.sharedInstance()
                continuation.resume(with: Result {
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
                    try session.setActive(true)
                })
            }
        }
    }
}
