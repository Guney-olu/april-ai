import SwiftUI

struct LocalView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            serviceStrip

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if state.localMessages.isEmpty && state.localStreamingReply.isEmpty {
                            LocalEmptyState()
                        }
                        ForEach(state.localMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if !state.localStreamingReply.isEmpty {
                            LocalStreamingBubble(text: state.localStreamingReply)
                                .id("local-stream")
                        }
                    }
                    .padding(18)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
                .onChange(of: state.localMessages.count) {
                    if let last = state.localMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: state.localStreamingReply) {
                    if !state.localStreamingReply.isEmpty {
                        proxy.scrollTo("local-stream", anchor: .bottom)
                    }
                }
            }

            Divider()
            composer
        }
    }

    private var serviceStrip: some View {
        HStack(spacing: 10) {
            ForEach(state.localServiceHealth) { health in
                Label(health.service.rawValue, systemImage: health.isReachable ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(health.isReachable ? .green : .secondary)
                    .help(health.detail)
            }
            Spacer()
            if state.isLocalBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Test services") {
                state.testLocalServices()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    state.startOrStopLocalVoice()
                } label: {
                    Label(
                        state.voiceRecorder.isRecording ? "Send voice" : "Record voice",
                        systemImage: state.voiceRecorder.isRecording ? "stop.circle.fill" : "mic.circle"
                    )
                }
                .buttonStyle(.bordered)

                Text(state.voiceRecorder.isRecording ? "Recording. Click Send voice when you are done." : "Turn-based local voice: macOS transcribes, Unsloth answers, Cartesia Sonic speaks.")
                    .font(.caption)
                    .foregroundStyle(state.voiceRecorder.isRecording ? .red : .secondary)
                Spacer()
                Button("Stop speech") { state.stopSpeech() }
                    .buttonStyle(.bordered)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask the local model. Its server tools are enabled.", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
                    .onSubmit { state.sendLocalDraft() }

                Button("Send") {
                    state.sendLocalDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLocalBusy)
            }
        }
        .padding(14)
        .background(.bar)
    }
}

private struct LocalEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Local April", systemImage: "cpu")
                .font(.headline.weight(.bold))
                .foregroundStyle(.orange)
            Text("Your Unsloth model, shared context, approved memory, and local voice services. Configure endpoints in Settings, then test them here.")
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct LocalStreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 9) {
                Label("April AI Local", systemImage: "cpu")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Text(text)
                    .textSelection(.enabled)
                ProgressView()
                    .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: 860, alignment: .leading)
            .background(Color.orange.opacity(0.09))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 80)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
