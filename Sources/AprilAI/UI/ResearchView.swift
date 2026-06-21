import SwiftUI

struct ResearchView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deep Research")
                .font(.title2.weight(.bold))

            Text("Runs a cited research-style prompt with optional Google Search grounding and saves the report into `context/research`.")
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom) {
                TextField("Research topic", text: $state.researchTopic, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)

                Button("Run Research") {
                    state.runResearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.researchTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Toggle("Use Gemini Google Search grounding for research", isOn: $state.settings.useGoogleSearchForResearch)

            Divider()

            List(state.context.reports) { report in
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.topic)
                        .font(.headline)
                    Text(report.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(report.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
    }
}
