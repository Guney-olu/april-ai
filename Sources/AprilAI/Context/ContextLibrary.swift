import Foundation
import PDFKit

@MainActor
final class ContextLibrary: ObservableObject {
    @Published private(set) var rootURL: URL
    @Published private(set) var documents: [IndexedDocument] = []
    @Published private(set) var memories: [MemoryItem] = []
    @Published private(set) var memoryClusters: [MemoryCluster] = []
    @Published private(set) var reports: [ResearchReport] = []
    @Published private(set) var agentTasks: [AgentTask] = []
    @Published private(set) var lastIndexSummary = "Not indexed yet."

    private var index: SQLiteIndex
    private var memoryStore: MemoryStore
    private let fileManager = FileManager.default

    init(rootURL: URL? = nil) throws {
        let defaultRoot = try Self.defaultRootURL()
        let resolvedRoot = rootURL ?? defaultRoot
        self.rootURL = resolvedRoot

        try Self.ensureFolderTree(at: resolvedRoot)
        let databaseURL = resolvedRoot.appending(path: "index/context.sqlite3")
        self.index = try SQLiteIndex(databaseURL: databaseURL)
        self.memoryStore = try MemoryStore(databaseURL: databaseURL)
        self.reports = Self.loadJSON([ResearchReport].self, from: resolvedRoot.appending(path: "research/reports.json")) ?? []
        self.agentTasks = Self.loadJSON([AgentTask].self, from: resolvedRoot.appending(path: "research/agent_tasks.json"))
            ?? self.reports.map(\.asAgentTask)
        self.documents = try index.documents()
        try migrateLegacyMemoriesIfNeeded()
        try memoryStore.pruneEmptySessions()
        self.memories = try memoryStore.approvedMemories()
        self.memoryClusters = try memoryStore.clusters()
    }

    var inboxURL: URL { rootURL.appending(path: "inbox") }
    var memoryURL: URL { rootURL.appending(path: "memory") }
    var researchURL: URL { rootURL.appending(path: "research") }
    var logsURL: URL { rootURL.appending(path: "logs") }
    private var memoriesURL: URL { memoryURL.appending(path: "memories.json") }
    private var approvedMemoriesURL: URL { memoryURL.appending(path: "approved_memories.json") }
    private var reportsURL: URL { researchURL.appending(path: "reports.json") }
    private var agentTasksURL: URL { researchURL.appending(path: "agent_tasks.json") }

    func reindexInbox() async {
        do {
            let files = try collectIndexableFiles()
            var indexed = 0

            for file in files {
                guard let text = extractText(from: file), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
                let chunks = chunk(text)
                try index.upsert(path: file.path, title: file.lastPathComponent, modifiedAt: modifiedAt, chunks: chunks)
                indexed += 1
            }

            documents = try index.documents()
            lastIndexSummary = "Indexed \(indexed) file\(indexed == 1 ? "" : "s") from context/inbox."
        } catch {
            lastIndexSummary = error.localizedDescription
        }
    }

    func search(_ query: String, limit: Int = 6) -> [ContextReference] {
        (try? index.search(query, limit: limit)) ?? []
    }

    func searchMemories(_ query: String, embedding: [Float]?, limit: Int = 6, sessionIDs: Set<String> = []) -> [MemorySearchResult] {
        (try? memoryStore.search(query: query, queryEmbedding: embedding, limit: limit, sessionIDs: sessionIDs)) ?? []
    }

    func liveMemoryPacket(limit: Int = 8, sessionIDs: Set<String> = []) -> String {
        let source = sessionIDs.isEmpty
            ? memories
            : memoryClusters
                .filter { sessionIDs.contains($0.session.id) }
                .flatMap(\.memories)
        let uniqueSelected = Dictionary(grouping: source, by: \.id)
            .compactMap { $0.value.first }
            .sorted {
                if $0.importance == $1.importance {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.importance > $1.importance
            }
            .prefix(limit)

        guard !uniqueSelected.isEmpty else {
            return "No approved memories are available yet."
        }

        return uniqueSelected.map { memory in
            "- \(memory.type.rawValue), confidence \(String(format: "%.2f", memory.confidence)), source \(memory.source): \(memory.content)"
        }.joined(separator: "\n")
    }

    func saveMemory(
        _ content: String,
        embedding: [Float]? = nil,
        embeddingModel: String = AppSettings.defaultEmbeddingModel,
        dimensions: Int = AppSettings.defaultEmbeddingDimensions
    ) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = try memoryStore.saveManualMemory(
            content: trimmed,
            embedding: embedding,
            embeddingModel: embeddingModel,
            dimensions: dimensions
        )
        try writeMemoryArtifact(item)
        try refreshMemories()
    }

    func deleteMemory(_ memory: MemoryItem) throws {
        try memoryStore.deleteMemory(id: memory.id)
        try deleteMemoryArtifacts(for: memory)
        try refreshMemories()
    }

    func saveReviewedMemories(
        candidates: [MemoryCandidate],
        sessionTitle: String,
        sessionSummary: String,
        embeddings: [UUID: [Float]],
        embeddingModel: String,
        dimensions: Int
    ) throws {
        guard !candidates.isEmpty else { return }
        let sessionID = try memoryStore.saveSession(title: sessionTitle, summary: sessionSummary)

        for candidate in candidates {
            let item = try memoryStore.saveCandidate(
                candidate,
                source: "Session \(sessionID)",
                embedding: embeddings[candidate.id],
                embeddingModel: embeddingModel,
                dimensions: dimensions
            )
            try memoryStore.linkMemory(item.id, toSession: sessionID)
            try writeMemoryArtifact(item, sessionTitle: sessionTitle, sessionSummary: sessionSummary)
        }

        try refreshMemories()
    }

    func updateMemory(
        _ draft: MemoryEditDraft,
        embedding: [Float]?,
        embeddingModel: String,
        dimensions: Int
    ) throws {
        let item = try memoryStore.updateMemory(
            id: draft.id,
            type: draft.type,
            summary: draft.summary,
            content: draft.content,
            confidence: draft.confidence,
            importance: draft.importance,
            embedding: embedding,
            embeddingModel: embeddingModel,
            dimensions: dimensions
        )
        try writeMemoryArtifact(item)
        try refreshMemories()
    }

    func mergeMemories(
        ids: [String],
        type: MemoryKind,
        summary: String,
        content: String,
        embedding: [Float]?,
        embeddingModel: String,
        dimensions: Int
    ) throws {
        let item = try memoryStore.mergeMemories(
            ids: ids,
            type: type,
            summary: summary,
            content: content,
            embedding: embedding,
            embeddingModel: embeddingModel,
            dimensions: dimensions
        )
        try writeMemoryArtifact(item)
        try refreshMemories()
    }

    func saveResearch(topic: String, markdown: String) throws -> ResearchReport {
        let fileURL = researchURL.appending(path: "\(Self.timestampSlug())-research.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        let report = ResearchReport(topic: topic, path: fileURL.path)
        reports.insert(report, at: 0)
        try saveJSON(reports, to: reportsURL)

        let task = AgentTask(
            id: report.id,
            topic: topic,
            prompt: topic,
            kind: .localResearch,
            status: .completed,
            path: fileURL.path,
            outputText: markdown,
            createdAt: report.createdAt,
            updatedAt: report.createdAt
        )
        try upsertAgentTask(task)
        return report
    }

    func saveAgentTask(_ task: AgentTask) throws {
        try upsertAgentTask(task)
    }

    func saveAgentTaskOutput(_ task: AgentTask, markdown: String) throws -> AgentTask {
        let fileURL = researchURL.appending(path: "\(Self.timestampSlug())-agent-task.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        var updated = task
        updated.path = fileURL.path
        updated.outputText = markdown
        updated.updatedAt = Date()
        try upsertAgentTask(updated)
        return updated
    }

    func saveAgentEnvironmentSnapshot(task: AgentTask, tarData: Data) throws -> AgentTask {
        let fileURL = researchURL.appending(path: "\(Self.timestampSlug())-\(task.id.uuidString.prefix(8))-sandbox.tar")
        try tarData.write(to: fileURL, options: .atomic)
        var updated = task
        updated.artifactPath = fileURL.path
        updated.updatedAt = Date()
        try upsertAgentTask(updated)
        return updated
    }

    func updateRootURL(_ newRoot: URL) throws {
        rootURL = newRoot
        try Self.ensureFolderTree(at: rootURL)
        let databaseURL = rootURL.appending(path: "index/context.sqlite3")
        index = try SQLiteIndex(databaseURL: databaseURL)
        memoryStore = try MemoryStore(databaseURL: databaseURL)
        try migrateLegacyMemoriesIfNeeded()
        try memoryStore.pruneEmptySessions()
        memories = try memoryStore.approvedMemories()
        memoryClusters = try memoryStore.clusters()
        reports = Self.loadJSON([ResearchReport].self, from: reportsURL) ?? []
        agentTasks = Self.loadJSON([AgentTask].self, from: agentTasksURL) ?? reports.map(\.asAgentTask)
        documents = try index.documents()
    }

    private func refreshMemories() throws {
        try memoryStore.pruneEmptySessions()
        memories = try memoryStore.approvedMemories()
        memoryClusters = try memoryStore.clusters()
        try saveJSON(memories, to: approvedMemoriesURL)
    }

    private func upsertAgentTask(_ task: AgentTask) throws {
        if let index = agentTasks.firstIndex(where: { $0.id == task.id }) {
            agentTasks[index] = task
        } else {
            agentTasks.insert(task, at: 0)
        }
        agentTasks.sort { $0.updatedAt > $1.updatedAt }
        try saveJSON(agentTasks, to: agentTasksURL)
    }

    private func migrateLegacyMemoriesIfNeeded() throws {
        let legacy = Self.loadJSON([MemoryRecord].self, from: memoriesURL) ?? []
        try memoryStore.importLegacyMemories(legacy)
    }

    private func writeMemoryArtifact(
        _ item: MemoryItem,
        sessionTitle: String? = nil,
        sessionSummary: String? = nil
    ) throws {
        let memoryFileURL = memoryURL.appending(path: "\(Self.timestampSlug())-\(item.type.rawValue)-memory.md")
        let metadata = """
        # Memory

        ID: \(item.id)
        Type: \(item.type.rawValue)
        Confidence: \(String(format: "%.2f", item.confidence))
        Importance: \(String(format: "%.2f", item.importance))
        Source: \(item.source)

        ## Summary
        \(item.summary)

        ## Content
        \(item.content)
        """

        let sessionBlock: String
        if let sessionTitle, let sessionSummary {
            sessionBlock = "\n\n## Session\n\(sessionTitle)\n\n\(sessionSummary)\n"
        } else {
            sessionBlock = ""
        }

        try (metadata + sessionBlock).write(to: memoryFileURL, atomically: true, encoding: .utf8)
    }

    private func deleteMemoryArtifacts(for memory: MemoryItem) throws {
        guard let enumerator = fileManager.enumerator(
            at: memoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("ID: \(memory.id)") || text.contains(memory.content) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func collectIndexableFiles() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: inboxURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            return Self.supportedExtensions.contains(ext) ? url : nil
        }
    }

    private func extractText(from file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: file) else { return nil }
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        }

        if Self.textExtensions.contains(ext) {
            return try? String(contentsOf: file, encoding: .utf8)
        }

        return nil
    }

    private func chunk(_ text: String, maxCharacters: Int = 2600) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
        var chunks: [String] = []
        var current = ""

        for paragraph in normalized.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if current.count + trimmed.count > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }

            if trimmed.count > maxCharacters {
                var start = trimmed.startIndex
                while start < trimmed.endIndex {
                    let end = trimmed.index(start, offsetBy: maxCharacters, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
                    chunks.append(String(trimmed[start..<end]))
                    start = end
                }
            } else {
                current += current.isEmpty ? trimmed : "\n\n\(trimmed)"
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func defaultRootURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appending(path: "AprilAI/context")
        let legacyRoot = appSupport.appending(path: "PolymathAssistant/context")

        if
            !FileManager.default.fileExists(atPath: root.path),
            FileManager.default.fileExists(atPath: legacyRoot.path)
        {
            try? FileManager.default.createDirectory(
                at: root.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: legacyRoot, to: root)
        }

        return root
    }

    private static func ensureFolderTree(at root: URL) throws {
        for folder in ["inbox", "memory", "research", "index", "logs"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: folder),
                withIntermediateDirectories: true
            )
        }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func timestampSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "html", "htm", "xml", "log",
        "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "c", "cpp", "h"
    ]

    private static let supportedExtensions: Set<String> = textExtensions.union(["pdf"])
}
