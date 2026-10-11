import SwiftUI

/// The spoken question, Gemini's answer and what to do next, shown in the map's search sheet.
struct AssistantCard: View {
    @ObservedObject var assistant: VoiceAssistant
    let onListen: () -> Void
    let onShowPlace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ask InView", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: assistant.phase == .listening)
                Spacer()
                Button { assistant.dismiss() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 28, height: 28)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close answer")
            }
            switch assistant.phase {
            case .idle:
                EmptyView()
            case .listening:
                Text(assistant.question.isEmpty ? "Listening…" : assistant.question)
                    .foregroundStyle(assistant.question.isEmpty ? .secondary : .primary)
                Button("Done", action: onListen).buttonStyle(.bordered).buttonBorderShape(.capsule)
            case .thinking:
                question
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            case .answered:
                question
                Text(assistant.reply)
                HStack(spacing: 10) {
                    if let place = assistant.place {
                        Button(action: onShowPlace) {
                            Label("Show on map", systemImage: "mappin.and.ellipse").font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .accessibilityLabel("Show \(place.name), Floor \(place.floor), on the map")
                    }
                    askAgain
                }
            case .failed(let message):
                if !assistant.question.isEmpty { question }
                Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
                askAgain
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
    }

    private var question: some View {
        Text("“\(assistant.question)”").font(.subheadline).foregroundStyle(.secondary)
            .accessibilityLabel("You asked: \(assistant.question)")
    }

    private var askAgain: some View {
        Button(action: onListen) {
            Label("Ask again", systemImage: "mic.fill").font(.subheadline.weight(.medium))
        }
        .buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
}
