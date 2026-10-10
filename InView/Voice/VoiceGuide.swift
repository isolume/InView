import AVFoundation

/// Speaks navigation prompts with the system voice. Urgent prompts cut off whatever is playing.
@MainActor
final class VoiceGuide {
    private let synthesizer = AVSpeechSynthesizer()
    /// The best installed English voice: premium or enhanced if the user downloaded one.
    private let voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == "en-US" }
        .max { $0.quality.rawValue < $1.quality.rawValue }
        ?? AVSpeechSynthesisVoice(language: "en-US")

    /// Audio session changes can block for a moment, so they happen off the main thread.
    private static let sessionQueue = DispatchQueue(label: "VoiceGuide.audioSession")

    func activate() {
        Self.sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
            try? session.setActive(true)
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
