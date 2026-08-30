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
                .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
                .onChange(of: state.messages.count) {
                    if let last = state.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        controlButton("Look", systemImage: "display", action: state.lookAtScreen)
                        controlButton(
                            liveMicButtonTitle,
                            systemImage: state.liveSession.isStreamingMic ? "stop.circle" : "mic.circle",
                            action: state.startOrStopVoice
                        )
                        controlButton(
                            state.isLiveScreenSharing ? "Stop screen" : "Share screen",
                            systemImage: state.isLiveScreenSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                            action: state.toggleLiveScreenShare
                        )
                        controlButton("Disconnect", systemImage: "bolt.slash", action: state.disconnectLive)
                        controlButton("Memory", systemImage: "arrow.clockwise", action: state.refreshLiveMemoryContextButton)
                            .disabled(!state.liveSession.isConnected)
                        controlButton("Speak", systemImage: "speaker.wave.2", action: state.speakLastAssistantMessage)
                        controlButton("Silence", systemImage: "speaker.slash", action: state.stopSpeech)
                    }
                }

                HStack(spacing: 8) {
                    StatusPill(
                        title: state.liveSession.isConnected ? "Live" : "Offline",
                        systemImage: state.liveSession.isConnected ? "bolt.fill" : "bolt.slash",
                        color: state.liveSession.isConnected ? .green : .secondary
                    )
                    if state.liveSession.isStreamingMic {
                        StatusPill(title: "Mic", systemImage: "mic.fill", color: .green)
                    }
                    if state.isLiveScreenSharing {
                        StatusPill(title: "Screen", systemImage: "rectangle.on.rectangle", color: .orange)
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
            .padding(14)
            .background(.bar)
        }
    }

    private var liveMicButtonTitle: String {
        if state.speech.isSpeaking {
            return state.liveSession.isStreamingMic ? "Pause live mic" : "Interrupt and talk"
        }
        return state.liveSession.isStreamingMic ? "Pause live mic" : "Start live mic"
    }

    private func controlButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(titleColor)
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(titleColor)
                    Spacer(minLength: 0)
                    Text(message.createdAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

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
            .frame(maxWidth: 860, alignment: .leading)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if message.role != .user {
                Spacer(minLength: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch message.role {
        case .user: "You"
        case .assistant: message.provider == .local ? "April AI Local" : "April AI"
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

    private var icon: String {
        switch message.role {
        case .assistant: message.provider == .local ? "cpu" : "sparkles"
        case .user: "person.crop.circle"
        case .system: "gearshape"
        }
    }

    private var background: Color {
        switch message.role {
        case .assistant: Color.green.opacity(0.09)
        case .user: Color.blue.opacity(0.12)
        case .system: Color.secondary.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .assistant: Color.green.opacity(0.18)
        case .user: Color.blue.opacity(0.20)
        case .system: Color.secondary.opacity(0.15)
        }
    }
}
