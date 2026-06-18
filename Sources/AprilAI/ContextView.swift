import SwiftUI

struct ContextView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Context Folder")
                    .font(.headline)
                Text(state.context.rootURL.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        state.openContextFolder()
                    } label: {
                        Label("Open folder", systemImage: "folder")
                    }

                    Button {
                        state.chooseContextFolder()
                    } label: {
                        Label("Choose folder", systemImage: "folder.badge.gearshape")
                    }

                    Button {
                        state.indexContext()
                    } label: {
                        Label("Index inbox", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            Text("Drop PDFs, Markdown, text, notes, logs, or code into `context/inbox`. The app indexes them for local reference search.")
                .foregroundStyle(.secondary)

            Table(state.context.documents) {
                TableColumn("Title") { document in
                    Text(document.title)
                }
                TableColumn("Chunks") { document in
                    Text("\(document.chunkCount)")
                }
                TableColumn("Indexed") { document in
                    Text(document.indexedAt, style: .relative)
                }
                TableColumn("Path") { document in
                    Text(document.path)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
    }
}
