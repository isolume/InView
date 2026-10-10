import AVFoundation

/// Speaks navigation prompts one at a time in an ElevenLabs voice, falling back to the
/// system voice when there's no key or the network fails, so guidance never goes silent.
@MainActor
final class VoiceGuide: NSObject {
    private let client = ElevenLabsClient()
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var cache: [String: Data] = [:]
    private var queue: [String] = []
    private var isSpeaking = false
    /// Bumped on every interruption so audio fetched for a dropped prompt is never played.
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
    }

    func deactivate() {
        stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Fetches audio ahead of time for prompts that are likely to come up.
    func prefetch(_ phrases: [String]) {
        guard let client else { return }
        for phrase in phrases where cache[phrase] == nil {
            Task { [weak self] in
                guard let audio = try? await client.speech(for: phrase) else { return }
                self?.cache[phrase] = audio
            }
        }
    }

    /// Queues a prompt. Urgent prompts (reroutes, arrival) cut off whatever is playing.
    func say(_ text: String, interrupting: Bool = false) {
        if interrupting { stop() }
        queue.append(text)
        if !isSpeaking { speakNext() }
    }

    func stop() {
        generation += 1
        queue.removeAll()
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func speakNext() {
        guard !queue.isEmpty else {
            isSpeaking = false
            return
        }
        isSpeaking = true
        let text = queue.removeFirst()
        if let audio = cache[text] {
            play(audio, fallback: text)
            return
        }
        guard let client else {
            speakWithSystemVoice(text)
            return
        }
        let expected = generation
        Task { [weak self] in
            let audio = try? await client.speech(for: text)
            guard let self, self.generation == expected else { return }
            if let audio {
                self.cache[text] = audio
                self.play(audio, fallback: text)
            } else {
                self.speakWithSystemVoice(text)
            }
        }
    }

    private func play(_ audio: Data, fallback text: String) {
        guard let player = try? AVAudioPlayer(data: audio) else {
            speakWithSystemVoice(text)
            return
        }
        player.delegate = self
        self.player = player
        player.play()
    }

    private func speakWithSystemVoice(_ text: String) {
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    fileprivate func finished() {
        player = nil
        speakNext()
    }
}

extension VoiceGuide: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
