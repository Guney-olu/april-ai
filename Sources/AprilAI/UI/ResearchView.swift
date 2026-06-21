import SwiftUI

struct ResearchView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                launcher
                taskList
            }
            .padding(18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent Lab")
                .font(.title2.weight(.bold))
            Text("Launch heavyweight sandbox work with Gemini Managed Agents, track outputs, and keep generated files under `context/research`.")
                .foregroundStyle(.secondary)
        }
    }

    private var launcher: some View {
        GroupBox("New Agent Task") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Mode", selection: $state.agentTaskKind) {
                            ForEach(AgentTaskKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Ask for a research job, computation, code/data analysis, artifact generation...", text: $state.agentTaskPrompt, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(4...10)
                    }

                    Button {
                        state.runAgentTask()
                    } label: {
                        Label("Run Agent", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.agentTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isBusy)
                }

                HStack {
                    Toggle("Download sandbox snapshot after run", isOn: $state.downloadAgentSnapshot)
                        .disabled(state.agentTaskKind == .localResearch)
                    Toggle("Use Google Search grounding for local research", isOn: $state.settings.useGoogleSearchForResearch)
                        .disabled(state.agentTaskKind != .localResearch)
                }
                .font(.callout)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var modeDescription: String {
        switch state.agentTaskKind {
        case .antigravity:
            return "Sandbox Agent uses Antigravity preview with code execution, web access, and sandbox files. Good for long compute, data work, scripts, and artifacts."
        case .deepResearch:
            return "Deep Research uses the managed sandbox agent with research-focused instructions, web verification, citations, and Markdown report output."
        case .localResearch:
            return "Local Research uses the existing Gemini text flow without a managed sandbox. Cheaper and faster for small cited summaries."
        }
    }

    private var taskList: some View {
        GroupBox("Task Tracker") {
            VStack(alignment: .leading, spacing: 10) {
                if state.context.agentTasks.isEmpty {
                    Text("No agent tasks yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.context.agentTasks) { task in
                        AgentTaskRow(task: task)
                    }
                }
            }
            .padding(8)
        }
    }
}

private struct AgentTaskRow: View {
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.topic)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(task.status.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor)
            }

            HStack {
                Label(task.kind.label, systemImage: icon)
                Text(task.updatedAt, style: .date)
                if !task.environmentID.isEmpty {
                    Text("Env \(task.environmentID)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !task.path.isEmpty {
                Text(task.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !task.artifactPath.isEmpty {
                Text("Snapshot: \(task.artifactPath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !task.error.isEmpty {
                Text(task.error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if !task.outputText.isEmpty {
                Text(task.outputText)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch task.kind {
        case .antigravity: "terminal"
        case .deepResearch: "doc.text.magnifyingglass"
        case .localResearch: "magnifyingglass"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .queued: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .requiresAction: .orange
        }
    }
}
