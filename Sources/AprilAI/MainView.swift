import SwiftUI

struct MainView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            List(WorkspaceTab.allCases, selection: $state.selectedTab) { tab in
                Label(tab.rawValue, systemImage: icon(for: tab))
                    .tag(tab)
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
        VStack(alignment: .leading, spacing: 8) {
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
