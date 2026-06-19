import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIdentityHeader(iconSize: 42, titleFont: .title3.weight(.bold))
                Spacer()
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            TextField("Ask fast. Think faster.", text: $state.draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.sendDraft() }
                .controlSize(.large)

            LazyVGrid(columns: columns, spacing: 10) {
                MenuActionButton(
                    title: "Send",
                    systemImage: "paperplane.fill",
                    isProminent: true,
                    action: state.sendDraft
                )
                MenuActionButton(
                    title: "Look",
                    systemImage: "display",
                    action: state.lookAtScreen
                )
                MenuActionButton(
                    title: talkButtonTitle,
                    systemImage: state.liveSession.isStreamingMic ? "stop.circle" : "mic.circle",
                    action: state.startOrStopVoice
                )
                MenuActionButton(
                    title: state.isLiveScreenSharing ? "Stop" : "Share",
                    systemImage: state.isLiveScreenSharing ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle",
                    action: state.toggleLiveScreenShare
                )
            }

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
        .padding(18)
        .frame(width: 392)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.white.opacity(0.04),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.13), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.32), radius: 24, y: 12)
        }
        .padding(1)
    }

    private var talkButtonTitle: String {
        if state.speech.isSpeaking {
            return state.liveSession.isStreamingMic ? "Pause" : "Interrupt"
        }
        return state.liveSession.isStreamingMic ? "Pause" : "Talk"
    }
}

private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isProminent ? Color.white : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isProminent ? Color.accentColor : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(isProminent ? 0.16 : 0.1), lineWidth: 1)
                )
        }
    }
}
