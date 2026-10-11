import Foundation

/// Hears a question, asks Gemini, and speaks the answer with ElevenLabs (or the system voice).
@MainActor
final class VoiceAssistant: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case answered
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    /// What the person said or typed.
    @Published private(set) var question = ""
    @Published private(set) var reply = ""
    /// The listed place that answers the question, if any.
    @Published private(set) var place: GeminiAssistantClient.Place?
    /// The person asked how to get to `place`, and maybe for the nearest of its kind.
    @Published private(set) var wantsDirections = false
    @Published private(set) var wantsNearest = false

    private let client = GeminiAssistantClient()
    private let listener = SpeechListener()
    /// Answers are full sentences, so ElevenLabs gets longer than a short navigation prompt would.
    private let voice = VoiceGuide(synthesisTimeout: 6)
    private var history: [GeminiAssistantClient.Turn] = []
    private var work: Task<Void, Never>?
    private static let rememberedTurns = 4

    var isAvailable: Bool { client != nil }

    /// Starts listening, or finishes the question early if already listening.
    func listen(context: GeminiAssistantClient.Context) {
        if phase == .listening { listener.stop(); return }
        reset()
        phase = .listening
        // Claims the audio session for this guide, so dismissing releases it even if nothing was said.
        voice.activate()
        let hints = context.places.map(\.name) + ["room", "elevator", "restroom", "bathroom", "floor"]
        work = Task {
            do {
                let heard = try await listener.listen(hints: hints) { [weak self] in self?.question = $0 }
                guard !Task.isCancelled else { return }
                guard !heard.isEmpty else { fail("I didn’t catch that. Tap the microphone and try again."); return }
                question = heard
                await answer(heard, context: context)
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func ask(_ text: String, context: GeminiAssistantClient.Context) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reset()
        question = text
        work = Task { await answer(text, context: context) }
    }

    func dismiss() {
        reset()
        voice.deactivate()
    }

    private func answer(_ text: String, context: GeminiAssistantClient.Context) async {
        guard let client else { fail("Add a Gemini API key to ask questions."); return }
        phase = .thinking
        do {
            let answer = try await client.answer(text, context: context, history: history)
            guard !Task.isCancelled else { return }
            reply = answer.reply
            place = context.places.first { $0.id == answer.placeID }
            wantsDirections = answer.wantsDirections && place != nil
            wantsNearest = answer.wantsNearest && place != nil
            phase = .answered
            history = Array((history + [.init(question: text, reply: answer.reply)]).suffix(Self.rememberedTurns))
            speak(answer.reply)
        } catch {
            guard !Task.isCancelled else { return }
            Log.assistant.error("Answer failed: \(error.localizedDescription, privacy: .public)")
            fail("Couldn’t get an answer. Check your connection and try again.")
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        speak(message)
    }

    private func speak(_ text: String) {
        voice.activate()
        voice.say(text, interrupting: true)
    }

    private func reset() {
        work?.cancel(); work = nil
        listener.cancel()
        voice.stop()
        phase = .idle
        question = ""; reply = ""; place = nil
        wantsDirections = false; wantsNearest = false
    }
}
