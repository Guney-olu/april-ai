import SwiftUI

struct ContextView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                contextHero
                inboxPanel
                documentSection
            }
            .padding(18)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.blue.opacity(0.035),
                    Color.green.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context")
                .font(.title2.weight(.bold))
            Text("Local files April can cite, search, and use as reference material.")
                .foregroundStyle(.secondary)
        }
    }

    private var contextHero: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.22), .green.opacity(0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Knowledge Base")
                            .font(.title3.weight(.bold))
                        Text(shortRootPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    ContextMetric(
                        title: "Files",
                        value: "\(state.context.documents.count)",
                        systemImage: "doc.text"
                    )
                    ContextMetric(
                        title: "Chunks",
                        value: "\(totalChunks)",
                        systemImage: "square.stack.3d.up"
                    )
                }

                Text(state.context.lastIndexSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        state.openContextFolder()
                    } label: {
                        Label("Open", systemImage: "folder")
                    }

                    Button {
                        state.chooseContextFolder()
                    } label: {
                        Label("Choose", systemImage: "folder.badge.gearshape")
                    }

                    Button {
                        state.indexContext()
                    } label: {
                        Label("Index Inbox", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var inboxPanel: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 50, height: 50)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("Drop files into context/inbox")
                    .font(.headline)
                Text("PDFs, Markdown, text, notes, logs, and code become searchable local references after indexing.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Inbox")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(state.context.inboxURL.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Indexed Documents")
                    .font(.headline)
                Spacer()
                Text("\(state.context.documents.count) item\(state.context.documents.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if state.context.documents.isEmpty {
                emptyDocuments
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.context.documents) { document in
                        IndexedDocumentRow(document: document)
                    }
                }
            }
        }
    }

    private var emptyDocuments: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No indexed files yet")
                .font(.headline)
            Text("Put files in the inbox, then hit Index Inbox. April will use them as local reference instead of pretending memory appeared by magic.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.secondary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var totalChunks: Int {
        state.context.documents.reduce(0) { $0 + $1.chunkCount }
    }

    private var shortRootPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = state.context.rootURL.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private struct ContextMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline.monospacedDigit())
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct IndexedDocumentRow: View {
    let document: IndexedDocument

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fileAccent.opacity(0.14))
                Image(systemName: fileIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(fileAccent)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(document.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 14)

            HStack(spacing: 8) {
                tag("\(document.chunkCount) chunks", systemImage: "square.stack")
                tag(relativeIndexedDate, systemImage: "clock")
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func tag(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))
            .clipShape(Capsule())
    }

    private var fileIcon: String {
        switch document.title.lowercased().split(separator: ".").last {
        case "pdf": "doc.richtext"
        case "md", "markdown": "text.alignleft"
        case "swift", "js", "ts", "py", "json", "html", "css": "chevron.left.forwardslash.chevron.right"
        default: "doc.text"
        }
    }

    private var fileAccent: Color {
        switch document.title.lowercased().split(separator: ".").last {
        case "pdf": .red
        case "md", "markdown": .blue
        case "swift", "js", "ts", "py", "json", "html", "css": .orange
        default: .green
        }
    }

    private var relativeIndexedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: document.indexedAt, relativeTo: Date())
    }
}
