import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppIdentityHeader()
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
                StatusPill(
                    title: state.liveSession.isConnected ? "Live" : "Idle",
                    systemImage: state.liveSession.isConnected ? "bolt.fill" : "moon",
                    color: state.liveSession.isConnected ? .green : .secondary
                )
                if state.isLiveScreenSharing {
                    StatusPill(title: "Screen", systemImage: "rectangle.on.rectangle", color: .orange)
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
