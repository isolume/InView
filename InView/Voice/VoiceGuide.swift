import AVFoundation

/// Plays prompts in order, using ElevenLabs when configured and the system voice if synthesis
/// fails or exceeds the timeout (2.5 seconds by default). Urgent prompts cancel queued and playing speech.
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
    private let synthesisTimeout: TimeInterval
    private var synthesisTask: Task<Void, Never>?
    private var pendingLines: [String] = []
    private var playbackCompletion: CheckedContinuation<Bool, Never>?
    private var utterance: AVSpeechUtterance?
    private var generation = 0

    /// Whether this guide activated the shared audio session, and so may deactivate it.
    private var isActive = false

    /// Audio session changes can block for a moment, so they happen off the main thread. Anything else
    /// that reconfigures the shared session uses this queue too, so changes apply in order.
    nonisolated static let sessionQueue = DispatchQueue(label: "VoiceGuide.audioSession")

    init(synthesisTimeout: TimeInterval = 2.5) {
        self.synthesisTimeout = synthesisTimeout
        super.init()
        synthesizer.delegate = self
    }

    func activate() {
        isActive = true
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

    /// Leaves the session alone unless this guide activated it, so it doesn't cut off other speech.
    func deactivate() {
        stop()
        guard isActive else { return }
        isActive = false
        Self.sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func say(_ text: String, interrupting: Bool = false) {
        if interrupting { stop() }
        pendingLines.append(text)
        guard synthesisTask == nil else { return }
        let generation = generation
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { self.synthesisTask = nil }
            }
            while !Task.isCancelled, !self.pendingLines.isEmpty {
                let text = self.pendingLines.removeFirst()
                var data = self.audioCache[text]
                if data == nil, let elevenLabs = self.elevenLabs {
                    data = try? await withTimeout(self.synthesisTimeout) {
                        try await elevenLabs.synthesize(text)
                    }
                    guard !Task.isCancelled else { return }
                    if let data { self.cache(text, data: data) }
                }
                guard !Task.isCancelled else { return }
                if let data, await self.play(data) { continue }
                guard !Task.isCancelled else { return }
                await self.speakWithSystemVoice(text)
            }
        }
    }

    func stop() {
        generation += 1
        synthesisTask?.cancel()
        synthesisTask = nil
        pendingLines.removeAll()
        completePlayback(false)
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    private func speakWithSystemVoice(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
        self.utterance = utterance
        _ = await withCheckedContinuation { continuation in
            playbackCompletion = continuation
            synthesizer.speak(utterance)
        }
        if self.utterance === utterance { self.utterance = nil }
    }

    private func play(_ data: Data) async -> Bool {
        guard let player = try? AVAudioPlayer(data: data) else { return false }
        self.player = player
        player.delegate = self
        let finished = await withCheckedContinuation { continuation in
            playbackCompletion = continuation
            if !player.play() { completePlayback(false) }
        }
        if self.player === player { self.player = nil }
        return finished
    }

    private func completePlayback(_ finished: Bool) {
        let completion = playbackCompletion
        playbackCompletion = nil
        completion?.resume(returning: finished)
    }

    private func cache(_ text: String, data: Data) {
        if audioCache.count >= Self.maxCachedLines { audioCache.removeAll() }
        audioCache[text] = data
    }
}

extension VoiceGuide: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.completePlayback(flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.completePlayback(false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.completePlayback(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.completePlayback(false)
        }
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
