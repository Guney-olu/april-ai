import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                AppIdentityHeader()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                List(WorkspaceTab.allCases, selection: $state.selectedTab) { tab in
                    Label(tab.rawValue, systemImage: icon(for: tab))
                        .tag(tab)
                        .font(.callout.weight(.medium))
                        .padding(.vertical, 4)
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("April AI")
            .safeAreaInset(edge: .bottom) {
                StatusBar()
                    .padding()
            }
        } detail: {
            Group {
                switch state.selectedTab {
                case .chat:
                    ChatView()
                case .context:
                    ContextView()
                case .research:
                    ResearchView()
                case .memory:
                    MemoryView()
                case .settings:
                    SettingsView()
                }
            }
            .navigationTitle(state.selectedTab.rawValue)
        }
    }

    private func icon(for tab: WorkspaceTab) -> String {
        switch tab {
        case .chat: "bubble.left.and.bubble.right"
        case .context: "folder"
        case .research: "doc.text.magnifyingglass"
        case .memory: "archivebox"
        case .settings: "gearshape"
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                StatusPill(
                    title: state.liveSession.isConnected ? "Live" : "Idle",
                    systemImage: state.liveSession.isConnected ? "bolt.fill" : "moon",
                    color: state.liveSession.isConnected ? .green : .secondary
                )
                if state.isLiveScreenSharing {
                    StatusPill(title: "Screen", systemImage: "rectangle.on.rectangle", color: .orange)
                }
                if state.liveSession.isStreamingMic {
                    StatusPill(title: "Mic", systemImage: "mic.fill", color: .green)
                }
            }

            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(state.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppIdentityHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("April AI")
                    .font(.headline.weight(.bold))
                Text("Polymath engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct StatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.13))
            .clipShape(Capsule())
    }
}
