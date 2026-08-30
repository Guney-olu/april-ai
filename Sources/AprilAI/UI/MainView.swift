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
                case .local:
                    LocalView()
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
        case .local: "desktopcomputer"
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
                    color: state.liveSession.isConnected ? .green : .secondary,
                    compact: true
                )
                if state.isLiveScreenSharing {
                    StatusPill(title: "Screen", systemImage: "rectangle.on.rectangle", color: .orange, compact: true)
                }
                if state.liveSession.isStreamingMic {
                    StatusPill(title: "Mic", systemImage: "mic.fill", color: .green, compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
    var iconSize: CGFloat = 38
    var titleFont: Font = .headline.weight(.bold)

    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            Text("April AI")
                .font(titleFont)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            Spacer()
        }
    }
}

struct StatusPill: View {
    let title: String
    let systemImage: String
    let color: Color
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .frame(width: 30, height: 24)
            } else {
                Label(title, systemImage: systemImage)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .foregroundStyle(color)
        .background(color.opacity(0.13))
        .clipShape(Capsule())
        .help(title)
    }
}
