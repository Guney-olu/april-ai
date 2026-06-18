import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(18)
                }
                .onChange(of: state.messages.count) {
                    if let last = state.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            VStack(spacing: 10) {
                HStack {
                    Button {
                        state.lookAtScreen()
                    } label: {
                        Label("Look at screen", systemImage: "display")
                    }

                    Button {
                        state.startOrStopVoice()
                    } label: {
                        Label(
                            liveMicButtonTitle,
                            systemImage: state.liveSession.isStreamingMic ? "stop.circle" : "mic.circle"
                        )
                    }

                    Button {
                        state.toggleLiveScreenShare()
                    } label: {
                        Label(
                            state.isLiveScreenSharing ? "Stop live screen" : "Share live screen",
                            systemImage: state.isLiveScreenSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle"
                        )
                    }

                    Button {
                        state.disconnectLive()
                    } label: {
                        Label("Disconnect live", systemImage: "bolt.slash")
                    }

                    Button {
                        state.refreshLiveMemoryContextButton()
                    } label: {
                        Label("Refresh memory", systemImage: "arrow.clockwise")
                    }
                    .disabled(!state.liveSession.isConnected)

                    Button {
                        state.speakLastAssistantMessage()
                    } label: {
                        Label("Speak short", systemImage: "speaker.wave.2")
                    }

                    Button {
                        state.stopSpeech()
                    } label: {
                        Label("Stop speech", systemImage: "speaker.slash")
                    }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    Circle()
                        .fill(state.liveSession.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(state.liveSession.isConnected ? "Live connected: \(state.settings.liveModel)" : "Live disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state.liveSession.isStreamingMic {
                        Text("Mic streaming")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if state.isLiveScreenSharing {
                        Text("Screen sharing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if state.liveSession.sentAudioChunkCount > 0 {
                        Text("\(state.liveSession.sentAudioChunkCount) audio chunks sent")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.liveSession.isStreamingMic {
                    Text("Speak now, then click Pause live mic. The model usually answers after the mic pauses or it detects silence.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask, plan, challenge, explain. Vague questions get verbally dissected.", text: $state.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                        .onSubmit {
                            state.sendDraft()
                        }

                    Button("Send") {
                        state.sendDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
    }

    private var liveMicButtonTitle: String {
        if state.speech.isSpeaking {
            return state.liveSession.isStreamingMic ? "Pause live mic" : "Interrupt and talk"
        }
        return state.liveSession.isStreamingMic ? "Pause live mic" : "Start live mic"
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(titleColor)

            Text(.init(message.content))
                .textSelection(.enabled)

            if message.role == .assistant, !message.spokenSummary.isEmpty {
                Label(message.spokenSummary, systemImage: "quote.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }

            if !message.references.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("References")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    ForEach(message.references) { reference in
                        Text("\(reference.source): \(reference.snippet)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        switch message.role {
        case .user: "You"
        case .assistant: "April AI"
        case .system: "System"
        }
    }

    private var titleColor: Color {
        switch message.role {
        case .assistant: .green
        case .user: .blue
        case .system: .secondary
        }
    }

    private var background: Color {
        switch message.role {
        case .assistant: Color.green.opacity(0.10)
        case .user: Color.blue.opacity(0.10)
        case .system: Color.secondary.opacity(0.10)
        }
    }
}
