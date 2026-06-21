import Foundation
import SQLite3

final class MemoryStore {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw MemoryStoreError.openFailed(message: lastError)
        }

        try createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    func approvedMemories() throws -> [MemoryItem] {
        var statement: OpaquePointer?
        let sql = """
        SELECT id, type, content, summary, source, confidence, importance, created_at, updated_at, status
        FROM memory_items
        WHERE status = 'approved'
        ORDER BY updated_at DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [MemoryItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(memoryItem(from: statement))
        }
        return rows
    }

    func sessions() throws -> [MemorySession] {
        var statement: OpaquePointer?
        let sql = """
        SELECT session_id, title, summary, created_at, approved_at
        FROM memory_sessions
        ORDER BY created_at DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [MemorySession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(memorySession(from: statement))
        }
        return rows
    }

    func clusters() throws -> [MemoryCluster] {
        let sessions = try sessions()
        let memoriesBySession = try memoryItemsBySession()
        var clusters = sessions.map { session in
            MemoryCluster(session: session, memories: memoriesBySession[session.id] ?? [])
        }

        let linkedIDs = Set(memoriesBySession.values.flatMap { $0.map(\.id) })
        let unlinked = try approvedMemories().filter { !linkedIDs.contains($0.id) }
        if !unlinked.isEmpty {
            clusters.append(MemoryCluster(
                session: MemorySession(
                    id: "manual-unlinked",
                    title: "Manual & Imported Memories",
                    summary: "Approved memories not tied to a saved session.",
                    createdAt: Date.distantPast,
                    approvedAt: nil
                ),
                memories: unlinked
            ))
        }
        return clusters
    }

    func importLegacyMemories(_ records: [MemoryRecord]) throws {
        guard !records.isEmpty else { return }

        for record in records {
            let trimmed = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, try !containsMemory(content: trimmed) else { continue }

            let kind = Self.classifyLegacyMemory(trimmed)
            let item = MemoryItem(
                id: UUID().uuidString,
                type: kind,
                content: trimmed,
                summary: trimmed,
                source: "Imported memories.json",
                confidence: 1.0,
                importance: 0.65,
                createdAt: record.createdAt,
                updatedAt: Date(),
                status: "approved"
            )
            try upsert(item: item, embedding: nil, embeddingModel: nil, dimensions: nil)
        }
    }

    func saveSession(title: String, summary: String) throws -> String {
        let id = UUID().uuidString
        try bindAndStep(
            """
            INSERT INTO memory_sessions(session_id, title, summary, created_at, approved_at)
            VALUES(?, ?, ?, ?, ?);
            """,
            .text(id),
            .text(title),
            .text(summary),
            .double(Date().timeIntervalSince1970),
            .double(Date().timeIntervalSince1970)
        )
        return id
    }

    func saveCandidate(
        _ candidate: MemoryCandidate,
        source: String,
        embedding: [Float]?,
        embeddingModel: String,
        dimensions: Int
    ) throws -> MemoryItem {
        let now = Date()
        let item = MemoryItem(
            id: UUID().uuidString,
            type: candidate.type,
            content: candidate.content.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: candidate.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            source: source,
            confidence: Self.clamped(candidate.confidence),
            importance: Self.clamped(candidate.importance),
            createdAt: now,
            updatedAt: now,
            status: "approved"
        )
        try upsert(item: item, embedding: embedding, embeddingModel: embeddingModel, dimensions: dimensions)
        return item
    }

    func linkMemory(_ memoryID: String, toSession sessionID: String) throws {
        try bindAndStep(
            """
            INSERT OR IGNORE INTO memory_session_items(session_id, memory_id, created_at)
            VALUES(?, ?, ?);
            """,
            .text(sessionID),
            .text(memoryID),
            .double(Date().timeIntervalSince1970)
        )
    }

    func saveManualMemory(
        content: String,
        embedding: [Float]?,
        embeddingModel: String,
        dimensions: Int
    ) throws -> MemoryItem {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let item = MemoryItem(
            id: UUID().uuidString,
            type: Self.classifyLegacyMemory(trimmed),
            content: trimmed,
            summary: trimmed,
            source: "Manual memory",
            confidence: 1.0,
            importance: 0.75,
            createdAt: now,
            updatedAt: now,
            status: "approved"
        )
        try upsert(item: item, embedding: embedding, embeddingModel: embeddingModel, dimensions: dimensions)
        return item
    }

    func deleteMemory(id: String) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try bindAndStep("DELETE FROM memory_embeddings WHERE memory_id = ?;", .text(id))
            try bindAndStep("DELETE FROM memory_fts WHERE memory_id = ?;", .text(id))
            try bindAndStep("DELETE FROM memory_links WHERE source_memory_id = ? OR target_memory_id = ?;", .text(id), .text(id))
            try bindAndStep("DELETE FROM memory_session_items WHERE memory_id = ?;", .text(id))
            try bindAndStep("DELETE FROM memory_items WHERE id = ?;", .text(id))
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func updateMemory(
        id: String,
        type: MemoryKind,
        summary: String,
        content: String,
        confidence: Double,
        importance: Double,
        embedding: [Float]?,
        embeddingModel: String,
        dimensions: Int
    ) throws -> MemoryItem {
        guard let existing = try memory(id: id) else {
            throw MemoryStoreError.queryFailed(message: "Memory \(id) was not found.")
        }
        let item = MemoryItem(
            id: existing.id,
            type: type,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            source: existing.source,
            confidence: Self.clamped(confidence),
            importance: Self.clamped(importance),
            createdAt: existing.createdAt,
            updatedAt: Date(),
            status: existing.status
        )
        try upsert(item: item, embedding: embedding, embeddingModel: embeddingModel, dimensions: dimensions)
        return item
    }

    func mergeMemories(
        ids: [String],
        type: MemoryKind,
        summary: String,
        content: String,
        embedding: [Float]?,
        embeddingModel: String,
        dimensions: Int
    ) throws -> MemoryItem {
        let uniqueIDs = Array(Set(ids))
        let sourceItems = try uniqueIDs.compactMap { try memory(id: $0) }
        let sessionIDs = try sessionIDs(forMemoryIDs: uniqueIDs)
        let confidence = sourceItems.map(\.confidence).max() ?? 0.8
        let importance = sourceItems.map(\.importance).max() ?? 0.8
        let now = Date()
        let merged = MemoryItem(
            id: UUID().uuidString,
            type: type,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            source: "Merged \(sourceItems.count) memories",
            confidence: confidence,
            importance: importance,
            createdAt: now,
            updatedAt: now,
            status: "approved"
        )

        try execute("BEGIN IMMEDIATE;")
        do {
            try upsertWithoutTransaction(item: merged, embedding: embedding, embeddingModel: embeddingModel, dimensions: dimensions)
            for sessionID in sessionIDs {
                try bindAndStep(
                    "INSERT OR IGNORE INTO memory_session_items(session_id, memory_id, created_at) VALUES(?, ?, ?);",
                    .text(sessionID),
                    .text(merged.id),
                    .double(now.timeIntervalSince1970)
                )
            }
            for id in uniqueIDs {
                try bindAndStep("DELETE FROM memory_embeddings WHERE memory_id = ?;", .text(id))
                try bindAndStep("DELETE FROM memory_fts WHERE memory_id = ?;", .text(id))
                try bindAndStep("DELETE FROM memory_links WHERE source_memory_id = ? OR target_memory_id = ?;", .text(id), .text(id))
                try bindAndStep("DELETE FROM memory_session_items WHERE memory_id = ?;", .text(id))
                try bindAndStep("DELETE FROM memory_items WHERE id = ?;", .text(id))
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }

        return merged
    }

    func search(query: String, queryEmbedding: [Float]?, limit: Int) throws -> [MemorySearchResult] {
        try search(query: query, queryEmbedding: queryEmbedding, limit: limit, sessionIDs: [])
    }

    func search(query: String, queryEmbedding: [Float]?, limit: Int, sessionIDs: Set<String>) throws -> [MemorySearchResult] {
        let queryTerms = Self.terms(in: query)
        let rows = try allMemoryRows(sessionIDs: sessionIDs)
        let now = Date()

        let scored = rows.compactMap { row -> MemorySearchResult? in
            let keywordScore = Self.keywordScore(queryTerms: queryTerms, item: row.item)
            let vectorScore = Self.cosine(queryEmbedding, row.embedding)
            let ageDays = max(0, now.timeIntervalSince(row.item.updatedAt) / 86_400)
            let recencyScore = exp(-ageDays / 90)

            guard keywordScore > 0 || vectorScore > 0.16 else {
                return nil
            }

            let score = (0.45 * vectorScore)
                + (0.25 * keywordScore)
                + (0.12 * row.item.importance)
                + (0.10 * row.item.confidence)
                + (0.08 * recencyScore)

            return MemorySearchResult(item: row.item, score: score)
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private func createTables() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS memory_items (
          id TEXT PRIMARY KEY,
          type TEXT NOT NULL,
          content TEXT NOT NULL,
          summary TEXT NOT NULL,
          source TEXT NOT NULL,
          confidence REAL NOT NULL,
          importance REAL NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          status TEXT NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS memory_embeddings (
          memory_id TEXT PRIMARY KEY,
          model TEXT NOT NULL,
          dimensions INTEGER NOT NULL,
          vector_blob BLOB NOT NULL,
          updated_at REAL NOT NULL,
          FOREIGN KEY(memory_id) REFERENCES memory_items(id) ON DELETE CASCADE
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS memory_sessions (
          session_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          summary TEXT NOT NULL,
          created_at REAL NOT NULL,
          approved_at REAL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS memory_links (
          source_memory_id TEXT NOT NULL,
          target_memory_id TEXT NOT NULL,
          relation_type TEXT NOT NULL,
          weight REAL NOT NULL,
          PRIMARY KEY(source_memory_id, target_memory_id, relation_type)
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS memory_session_items (
          session_id TEXT NOT NULL,
          memory_id TEXT NOT NULL,
          created_at REAL NOT NULL,
          PRIMARY KEY(session_id, memory_id),
          FOREIGN KEY(session_id) REFERENCES memory_sessions(session_id) ON DELETE CASCADE,
          FOREIGN KEY(memory_id) REFERENCES memory_items(id) ON DELETE CASCADE
        );
        """)

        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
          memory_id UNINDEXED,
          type,
          content,
          summary,
          source,
          tokenize = 'porter unicode61'
        );
        """)
    }

    private func upsert(
        item: MemoryItem,
        embedding: [Float]?,
        embeddingModel: String?,
        dimensions: Int?
    ) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try upsertWithoutTransaction(item: item, embedding: embedding, embeddingModel: embeddingModel, dimensions: dimensions)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func upsertWithoutTransaction(
        item: MemoryItem,
        embedding: [Float]?,
        embeddingModel: String?,
        dimensions: Int?
    ) throws {
        try bindAndStep(
            """
            INSERT INTO memory_items(id, type, content, summary, source, confidence, importance, created_at, updated_at, status)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              type = excluded.type,
              content = excluded.content,
              summary = excluded.summary,
              source = excluded.source,
              confidence = excluded.confidence,
              importance = excluded.importance,
              updated_at = excluded.updated_at,
              status = excluded.status;
            """,
            .text(item.id),
            .text(item.type.rawValue),
            .text(item.content),
            .text(item.summary),
            .text(item.source),
            .double(item.confidence),
            .double(item.importance),
            .double(item.createdAt.timeIntervalSince1970),
            .double(item.updatedAt.timeIntervalSince1970),
            .text(item.status)
        )

        try bindAndStep("DELETE FROM memory_fts WHERE memory_id = ?;", .text(item.id))
        try bindAndStep(
            "INSERT INTO memory_fts(memory_id, type, content, summary, source) VALUES(?, ?, ?, ?, ?);",
            .text(item.id),
            .text(item.type.rawValue),
            .text(item.content),
            .text(item.summary),
            .text(item.source)
        )

        if let embedding, let embeddingModel, let dimensions {
            try bindAndStep(
                """
                INSERT INTO memory_embeddings(memory_id, model, dimensions, vector_blob, updated_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(memory_id) DO UPDATE SET
                  model = excluded.model,
                  dimensions = excluded.dimensions,
                  vector_blob = excluded.vector_blob,
                  updated_at = excluded.updated_at;
                """,
                .text(item.id),
                .text(embeddingModel),
                .int(Int64(dimensions)),
                .blob(Self.data(fromVector: embedding)),
                .double(Date().timeIntervalSince1970)
            )
        }
    }

    private func containsMemory(content: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM memory_items WHERE content = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, content, -1, MEMORY_SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func memory(id: String) throws -> MemoryItem? {
        var statement: OpaquePointer?
        let sql = """
        SELECT id, type, content, summary, source, confidence, importance, created_at, updated_at, status
        FROM memory_items
        WHERE id = ?
        LIMIT 1;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, id, -1, MEMORY_SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return memoryItem(from: statement)
    }

    private func allMemoryRows(sessionIDs: Set<String> = []) throws -> [(item: MemoryItem, embedding: [Float]?)] {
        var statement: OpaquePointer?
        let filter = sessionIDs.isEmpty
            ? ""
            : "AND EXISTS (SELECT 1 FROM memory_session_items msi WHERE msi.memory_id = mi.id AND msi.session_id IN (\(Array(repeating: "?", count: sessionIDs.count).joined(separator: ","))))"
        let sql = """
        SELECT DISTINCT mi.id, mi.type, mi.content, mi.summary, mi.source, mi.confidence, mi.importance,
               mi.created_at, mi.updated_at, mi.status, me.vector_blob
        FROM memory_items mi
        LEFT JOIN memory_embeddings me ON me.memory_id = mi.id
        WHERE mi.status = 'approved'
        \(filter);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        for (index, sessionID) in sessionIDs.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), sessionID, -1, MEMORY_SQLITE_TRANSIENT)
        }

        var rows: [(MemoryItem, [Float]?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let item = memoryItem(from: statement)
            let embedding = vectorBlob(statement, 10)
            rows.append((item, embedding))
        }
        return rows
    }

    private func memoryItemsBySession() throws -> [String: [MemoryItem]] {
        var statement: OpaquePointer?
        let sql = """
        SELECT msi.session_id, mi.id, mi.type, mi.content, mi.summary, mi.source, mi.confidence, mi.importance,
               mi.created_at, mi.updated_at, mi.status
        FROM memory_session_items msi
        JOIN memory_items mi ON mi.id = msi.memory_id
        WHERE mi.status = 'approved'
        ORDER BY msi.created_at DESC, mi.updated_at DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: [MemoryItem]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = memoryColumnText(statement, 0)
            let item = MemoryItem(
                id: memoryColumnText(statement, 1),
                type: MemoryKind(rawValue: memoryColumnText(statement, 2)) ?? .semantic,
                content: memoryColumnText(statement, 3),
                summary: memoryColumnText(statement, 4),
                source: memoryColumnText(statement, 5),
                confidence: sqlite3_column_double(statement, 6),
                importance: sqlite3_column_double(statement, 7),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                status: memoryColumnText(statement, 10)
            )
            result[sessionID, default: []].append(item)
        }
        return result
    }

    private func sessionIDs(forMemoryIDs ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var statement: OpaquePointer?
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT DISTINCT session_id FROM memory_session_items WHERE memory_id IN (\(placeholders));"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }
        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, MEMORY_SQLITE_TRANSIENT)
        }
        var output = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            output.insert(memoryColumnText(statement, 0))
        }
        return output
    }

    private func memoryItem(from statement: OpaquePointer?) -> MemoryItem {
        MemoryItem(
            id: memoryColumnText(statement, 0),
            type: MemoryKind(rawValue: memoryColumnText(statement, 1)) ?? .semantic,
            content: memoryColumnText(statement, 2),
            summary: memoryColumnText(statement, 3),
            source: memoryColumnText(statement, 4),
            confidence: sqlite3_column_double(statement, 5),
            importance: sqlite3_column_double(statement, 6),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
            status: memoryColumnText(statement, 9)
        )
    }

    private func memorySession(from statement: OpaquePointer?) -> MemorySession {
        let approvedAt: Date?
        if sqlite3_column_type(statement, 4) == SQLITE_NULL {
            approvedAt = nil
        } else {
            approvedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        }
        return MemorySession(
            id: memoryColumnText(statement, 0),
            title: memoryColumnText(statement, 1),
            summary: memoryColumnText(statement, 2),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            approvedAt: approvedAt
        )
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
    }

    private func bindAndStep(_ sql: String, _ values: MemorySQLiteValue...) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, MEMORY_SQLITE_TRANSIENT)
            case .double(let number):
                sqlite3_bind_double(statement, position, number)
            case .int(let number):
                sqlite3_bind_int64(statement, position, number)
            case .blob(let data):
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(data.count), MEMORY_SQLITE_TRANSIENT)
                }
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(message: lastError)
        }
    }

    private var lastError: String {
        guard let db else { return "SQLite database is not open." }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func classifyLegacyMemory(_ text: String) -> MemoryKind {
        let lower = text.lowercased()
        if lower.contains("prefer") || lower.contains("preference") || lower.contains("likes") || lower.contains("style") {
            return .preference
        }
        if lower.contains("when ") && (lower.contains(" do ") || lower.contains(" use ")) {
            return .procedural
        }
        if lower.contains("remember to") {
            return .prospective
        }
        return .semantic
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func terms(in text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
            .prefix(12)
            .map { $0 }
    }

    private static func keywordScore(queryTerms: [String], item: MemoryItem) -> Double {
        guard !queryTerms.isEmpty else { return 0 }
        let haystack = "\(item.type.rawValue) \(item.content) \(item.summary) \(item.source)".lowercased()
        let matches = queryTerms.filter { haystack.contains($0) }.count
        return Double(matches) / Double(queryTerms.count)
    }

    private static func cosine(_ a: [Float]?, _ b: [Float]?) -> Double {
        guard let a, let b, a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0
        var magA = 0.0
        var magB = 0.0

        for index in a.indices {
            let av = Double(a[index])
            let bv = Double(b[index])
            dot += av * bv
            magA += av * av
            magB += bv * bv
        }

        guard magA > 0, magB > 0 else { return 0 }
        return max(0, dot / (sqrt(magA) * sqrt(magB)))
    }

    private static func data(fromVector vector: [Float]) -> Data {
        var copy = vector
        return copy.withUnsafeMutableBufferPointer { buffer in
            Data(UnsafeRawBufferPointer(buffer))
        }
    }
}

private enum MemorySQLiteValue {
    case text(String)
    case double(Double)
    case int(Int64)
    case blob(Data)
}

private func memoryColumnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let cString = sqlite3_column_text(statement, index) else {
        return ""
    }
    return String(cString: cString)
}

private func vectorBlob(_ statement: OpaquePointer?, _ index: Int32) -> [Float]? {
    let byteCount = Int(sqlite3_column_bytes(statement, index))
    guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
        return nil
    }

    let data = Data(bytes: bytes, count: byteCount)
    guard data.count % MemoryLayout<Float>.size == 0 else { return nil }
    return data.withUnsafeBytes { rawBuffer in
        Array(rawBuffer.bindMemory(to: Float.self))
    }
}

enum MemoryStoreError: LocalizedError {
    case openFailed(message: String)
    case queryFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "Could not open memory store: \(message)"
        case .queryFailed(let message):
            "Memory store failed: \(message)"
        }
    }
}

private let MEMORY_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
