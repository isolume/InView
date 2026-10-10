import AVFoundation

/// Speaks navigation prompts. Prefers ElevenLabs when a key is configured, falling back to the
/// system voice immediately on any failure, timeout, or missing key — navigation audio must
/// never wait on the network. Urgent prompts cut off whatever is playing.
@MainActor
final class VoiceGuide: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    /// The best installed English voice: premium or enhanced if the user downloaded one. Listing voices
    /// takes a noticeable moment the first time, so it happens off the main thread while activating.
    private var voice: AVSpeechSynthesisVoice?
    private let elevenLabs = ElevenLabsVoiceClient()
    /// Keyed by exact line text; lines repeat verbatim often enough during a route to make this worth it.
    private var audioCache: [String: Data] = [:]
    private static let maxCachedLines = 60
    private static let synthesisTimeout: TimeInterval = 2.5
    private var synthesisTask: Task<Void, Never>?

    /// Audio session changes can block for a moment, so they happen off the main thread.
    private static let sessionQueue = DispatchQueue(label: "VoiceGuide.audioSession")

    override init() {
        super.init()
    }

    func activate() {
        Self.sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try? session.setActive(true)
        }
        guard voice == nil else { return }
        Task { [weak self] in
            let best = await Task.detached(priority: .utility) {
                AVSpeechSynthesisVoice.speechVoices()
                    .filter { $0.language == "en-US" }
                    .max { $0.quality.rawValue < $1.quality.rawValue }
                    ?? AVSpeechSynthesisVoice(language: "en-US")
            }.value
            self?.voice = best
        }
    }

    func deactivate() {
        stop()
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func say(_ text: String, interrupting: Bool = false) {
        if interrupting { stop() }
        guard let elevenLabs else {
            speakWithSystemVoice(text)
            return
        }
        if let cached = audioCache[text] {
            play(cached, fallbackText: text)
            return
        }
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await withTimeout(Self.synthesisTimeout) {
                    try await elevenLabs.synthesize(text)
                }
                try Task.checkCancellation()
                self.cache(text, data: data)
                self.play(data, fallbackText: text)
            } catch {
                guard !Task.isCancelled else { return }
                self.speakWithSystemVoice(text)
            }
        }
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    private func play(_ data: Data, fallbackText: String) {
        guard let player = try? AVAudioPlayer(data: data) else {
            speakWithSystemVoice(fallbackText)
            return
        }
        self.player = player
        player.play()
    }

    private func cache(_ text: String, data: Data) {
        if audioCache.count >= Self.maxCachedLines { audioCache.removeAll() }
        audioCache[text] = data
    }
}

/// Races `operation` against a deadline; the loser is cancelled and its result discarded.
private func withTimeout<T: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
