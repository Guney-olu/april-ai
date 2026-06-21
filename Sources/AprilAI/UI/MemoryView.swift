import SwiftUI

struct MemoryView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                liveMemory
                manualMemory
                sessionReview
                memorySearch
                approvedMemories
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
            Text("Auto-save memory is on. April AI saves useful session memories locally, then you prune the dumb ones with the trash button.")
                .foregroundStyle(.secondary)
        }
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

    private var approvedMemories: some View {
        GroupBox("Approved Memories") {
            VStack(alignment: .leading, spacing: 8) {
                if state.context.memories.isEmpty {
                    Text("No approved memories yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.context.memories) { memory in
                        MemoryItemRow(memory: memory) {
                            state.deleteMemory(memory)
                        }
                    }
                }
            }
            .padding(8)
        }
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
    let memory: MemoryItem
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
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
                    onDelete()
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
