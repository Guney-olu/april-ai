import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                brainHero
                liveMemory
                manualMemory
                sessionReview
                memorySearch
                brainControls
                memoryBrain
                editor
            }
            .padding(18)
        }
    }

    private var liveMemory: some View {
        GroupBox("Live Memory") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.liveSession.isConnected ? "Live can use approved memory context." : "Live memory loads when a Live session connects.")
                        .foregroundStyle(.secondary)
                    Text("Live memory refreshes automatically after auto-save, manual save, or delete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.refreshLiveMemoryContextButton()
                } label: {
                    Label("Refresh Live Memory", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!state.liveSession.isConnected)
            }
            .padding(8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(.title2.weight(.bold))
            Text("Session memories are organized like a small external brain. Plug in one or more sessions to control what April AI recalls next.")
                .foregroundStyle(.secondary)
        }
    }

    private var brainHero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 18) {
                BrainModelView()
                    .frame(width: 230, height: 180)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Clean Brain")
                        .font(.title3.weight(.bold))
                    Text(state.context.memoryClusters.isEmpty
                         ? "No premade sessions. April grows memory only from saved conversations and manual notes."
                         : "\(state.context.memoryClusters.count) session brain\(state.context.memoryClusters.count == 1 ? "" : "s") available.")
                        .foregroundStyle(.secondary)
                    Text(state.activeMemorySessionIDs.isEmpty
                         ? "All approved memory is available."
                         : "\(state.activeMemorySessionIDs.count) session\(state.activeMemorySessionIDs.count == 1 ? "" : "s") plugged into recall.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.activeMemorySessionIDs.isEmpty ? Color.secondary : Color.green)
                }

                Spacer()
            }
            .padding(18)
        }
        .frame(minHeight: 210)
    }

    private var manualMemory: some View {
        GroupBox("Manual Memory") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    TextField("Remember this...", text: $state.pendingMemory, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)

                    Button("Save Memory") {
                        state.savePendingMemory()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.pendingMemory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Manual saves are approved immediately and embedded when the Gemini API key is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var sessionReview: some View {
        GroupBox("Session Memory") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button {
                        state.reviewSessionMemory()
                    } label: {
                        Label("Draft From Session", systemImage: "text.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        state.saveSelectedMemoryCandidates()
                    } label: {
                        Label("Save Selected", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(state.memoryCandidates.filter(\.isSelected).isEmpty)

                    Button {
                        state.skipSelectedMemoryCandidates()
                    } label: {
                        Label("Skip Selected", systemImage: "xmark.bin")
                    }
                    .disabled(state.memoryCandidates.filter(\.isSelected).isEmpty)
                }
                .buttonStyle(.bordered)

                if !state.sessionMemorySummary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.sessionMemoryTitle.isEmpty ? "Reviewed session" : state.sessionMemoryTitle)
                            .font(.headline)
                        Text(state.sessionMemorySummary)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if state.memoryCandidates.isEmpty {
                    Text("No pending candidates.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($state.memoryCandidates) { $candidate in
                            MemoryCandidateRow(candidate: $candidate)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var memorySearch: some View {
        GroupBox("Recall Test") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Search approved memories...", text: $state.memorySearchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            state.runMemorySearch()
                        }

                    Button {
                        state.runMemorySearch()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !state.memorySearchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.memorySearchResults) { result in
                            MemoryResultRow(result: result)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var brainControls: some View {
        GroupBox("Brain Controls") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(state.activeMemorySessionIDs.count) plugged session\(state.activeMemorySessionIDs.count == 1 ? "" : "s")", systemImage: "brain.head.profile")
                        .font(.headline)
                    Spacer()
                    Button {
                        state.clearActiveMemorySessions()
                    } label: {
                        Label("Use All", systemImage: "circle.grid.cross")
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.activeMemorySessionIDs.isEmpty)
                }

                Text(state.activeMemorySessionIDs.isEmpty
                     ? "April uses all approved memories for recall."
                     : "April recalls from the plugged sessions first. Live memory refreshes automatically.")
                    .foregroundStyle(.secondary)

                if state.selectedMemoryIDs.count >= 2 {
                    Divider()
                    HStack {
                        Picker("Merged type", selection: $state.mergeMemoryType) {
                            ForEach(MemoryKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 170)

                        Button {
                            state.mergeSelectedMemories()
                        } label: {
                            Label("Merge \(state.selectedMemoryIDs.count)", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    TextField("Merged memory", text: $state.mergeMemoryDraft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...8)
                }
            }
            .padding(8)
        }
    }

    private var memoryBrain: some View {
        GroupBox("Memory Brain") {
            VStack(alignment: .leading, spacing: 12) {
                if state.context.memoryClusters.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No memory sessions yet.")
                            .font(.headline)
                        Text("Start a chat, let April save useful session memories, or add a manual memory. This list stays empty until something real exists.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(state.context.memoryClusters) { cluster in
                        MemoryClusterSection(cluster: cluster)
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let draft = state.editingMemoryDraft {
            GroupBox("Edit Memory") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Type", selection: Binding(
                        get: { state.editingMemoryDraft?.type ?? draft.type },
                        set: { state.editingMemoryDraft?.type = $0 }
                    )) {
                        ForEach(MemoryKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Summary", text: Binding(
                        get: { state.editingMemoryDraft?.summary ?? draft.summary },
                        set: { state.editingMemoryDraft?.summary = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    TextField("Content", text: Binding(
                        get: { state.editingMemoryDraft?.content ?? draft.content },
                        set: { state.editingMemoryDraft?.content = $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...10)

                    HStack {
                        Stepper("Confidence \(state.editingMemoryDraft?.confidence ?? draft.confidence, specifier: "%.2f")", value: Binding(
                            get: { state.editingMemoryDraft?.confidence ?? draft.confidence },
                            set: { state.editingMemoryDraft?.confidence = $0 }
                        ), in: 0...1, step: 0.05)

                        Stepper("Importance \(state.editingMemoryDraft?.importance ?? draft.importance, specifier: "%.2f")", value: Binding(
                            get: { state.editingMemoryDraft?.importance ?? draft.importance },
                            set: { state.editingMemoryDraft?.importance = $0 }
                        ), in: 0...1, step: 0.05)
                    }

                    HStack {
                        Button("Cancel") {
                            state.cancelEditingMemory()
                        }
                        Button("Save Changes") {
                            state.saveEditingMemory()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(8)
            }
        }
    }
}

private struct MemoryClusterSection: View {
    @EnvironmentObject private var state: AppState
    let cluster: MemoryCluster

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Toggle("", isOn: Binding(
                    get: { state.activeMemorySessionIDs.contains(cluster.session.id) },
                    set: { _ in state.toggleMemorySession(cluster.session.id) }
                ))
                .labelsHidden()

                VStack(alignment: .leading, spacing: 4) {
                    Text(cluster.session.title)
                        .font(.headline)
                    Text(cluster.session.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("\(cluster.memories.count) memor\(cluster.memories.count == 1 ? "y" : "ies") | \(cluster.session.createdAt, style: .date)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(state.activeMemorySessionIDs.contains(cluster.session.id) ? "Plugged" : "Dormant")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.activeMemorySessionIDs.contains(cluster.session.id) ? .green : .secondary)
            }

            ForEach(cluster.memories) { memory in
                MemoryItemRow(memory: memory)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MemoryCandidateRow: View {
    @Binding var candidate: MemoryCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("", isOn: $candidate.isSelected)
                    .labelsHidden()

                Picker("Type", selection: $candidate.type) {
                    ForEach(MemoryKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Text(candidate.sensitivity.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(candidate.sensitivity.lowercased() == "high" ? .red : .secondary)

                Spacer()

                Text("C \(candidate.confidence, specifier: "%.2f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("I \(candidate.importance, specifier: "%.2f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TextField("Summary", text: $candidate.summary)
                .textFieldStyle(.roundedBorder)

            TextField("Memory content", text: $candidate.content, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            Text(candidate.reason.isEmpty ? candidate.evidence : "\(candidate.reason) Evidence: \(candidate.evidence)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MemoryItemRow: View {
    @EnvironmentObject private var state: AppState
    let memory: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { state.selectedMemoryIDs.contains(memory.id) },
                    set: { _ in state.toggleSelectedMemory(memory.id) }
                ))
                .labelsHidden()

                Text(memory.type.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
                Text(memory.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(memory.updatedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    state.startEditingMemory(memory)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                Button {
                    state.deleteMemory(memory)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            Text(memory.content)
                .textSelection(.enabled)
            Text("Confidence \(memory.confidence, specifier: "%.2f") | Importance \(memory.importance, specifier: "%.2f")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct MemoryResultRow: View {
    let result: MemorySearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.item.type.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                Text("score \(result.score, specifier: "%.2f")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(result.item.content)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
