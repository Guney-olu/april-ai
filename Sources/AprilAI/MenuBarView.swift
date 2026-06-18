import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("April AI")
                        .font(.headline)
                    Text("Ask. Get challenged. Move.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            TextField("Ask fast. Think faster.", text: $state.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.sendDraft() }

            HStack {
                Button {
                    state.sendDraft()
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                    .buttonStyle(.borderedProminent)
                Button {
                    state.lookAtScreen()
                } label: {
                    Label("Screen", systemImage: "display")
                }
                Button {
                    state.startOrStopVoice()
                } label: {
                    Label(
                        talkButtonTitle,
                        systemImage: state.liveSession.isStreamingMic ? "stop.circle" : "mic.circle"
                    )
                }
                Button {
                    state.toggleLiveScreenShare()
                } label: {
                    Label(
                        state.isLiveScreenSharing ? "Stop screen" : "Share screen",
                        systemImage: state.isLiveScreenSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle"
                    )
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 7) {
                Circle()
                    .fill(state.liveSession.isConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(state.liveSession.isConnected ? "Live ready" : "Live opens on Talk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.isLiveScreenSharing {
                    Text("Screen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                if state.liveSession.sentAudioChunkCount > 0 {
                    Text("\(state.liveSession.sentAudioChunkCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if state.liveSession.isConnected {
                    Button("Close") {
                        state.disconnectLive()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }

            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if state.liveSession.isStreamingMic {
                Text("Speak, then press Pause.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(width: 380)
    }

    private var talkButtonTitle: String {
        if state.speech.isSpeaking {
            return state.liveSession.isStreamingMic ? "Pause" : "Interrupt"
        }
        return state.liveSession.isStreamingMic ? "Pause" : "Talk"
    }
}
