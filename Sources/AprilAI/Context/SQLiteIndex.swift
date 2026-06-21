import Foundation
import SQLite3

final class SQLiteIndex {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw IndexError.openFailed(message: lastError)
        }

        try execute("""
        CREATE TABLE IF NOT EXISTS documents (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          path TEXT UNIQUE NOT NULL,
          title TEXT NOT NULL,
          modified_at REAL NOT NULL,
          indexed_at REAL NOT NULL,
          chunk_count INTEGER NOT NULL
        );
        """)

        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
          source,
          content,
          document_id UNINDEXED,
          tokenize = 'porter unicode61'
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    func upsert(path: String, title: String, modifiedAt: Date, chunks: [String]) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try bindAndStep(
                "INSERT INTO documents(path, title, modified_at, indexed_at, chunk_count) VALUES(?, ?, ?, ?, ?) " +
                "ON CONFLICT(path) DO UPDATE SET title = excluded.title, modified_at = excluded.modified_at, indexed_at = excluded.indexed_at, chunk_count = excluded.chunk_count;",
                .text(path),
                .text(title),
                .double(modifiedAt.timeIntervalSince1970),
                .double(Date().timeIntervalSince1970),
                .int(Int64(chunks.count))
            )

            let documentID = try documentID(for: path)
            try bindAndStep("DELETE FROM chunks WHERE document_id = ?;", .int(documentID))

            for chunk in chunks {
                try bindAndStep(
                    "INSERT INTO chunks(source, content, document_id) VALUES(?, ?, ?);",
                    .text(title),
                    .text(chunk),
                    .int(documentID)
                )
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func documents() throws -> [IndexedDocument] {
        var statement: OpaquePointer?
        let sql = "SELECT id, path, title, modified_at, indexed_at, chunk_count FROM documents ORDER BY indexed_at DESC;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [IndexedDocument] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                IndexedDocument(
                    id: sqlite3_column_int64(statement, 0),
                    path: columnText(statement, 1),
                    title: columnText(statement, 2),
                    modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    chunkCount: Int(sqlite3_column_int64(statement, 5))
                )
            )
        }
        return rows
    }

    func search(_ query: String, limit: Int = 6) throws -> [ContextReference] {
        let terms = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 }
            .prefix(8)

        guard !terms.isEmpty else {
            return []
        }

        let ftsQuery = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " OR ")
        var statement: OpaquePointer?
        let sql = """
        SELECT source, snippet(chunks, 1, '[', ']', '...', 20)
        FROM chunks
        WHERE chunks MATCH ?
        LIMIT ?;
        """

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var rows: [ContextReference] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(ContextReference(source: columnText(statement, 0), snippet: columnText(statement, 1)))
        }
        return rows
    }

    private func documentID(for path: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM documents WHERE path = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IndexError.queryFailed(message: "Missing document after upsert.")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: lastError)
        }
    }

    private func bindAndStep(_ sql: String, _ values: SQLiteValue...) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw IndexError.queryFailed(message: lastError)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .double(let number):
                sqlite3_bind_double(statement, position, number)
            case .int(let number):
                sqlite3_bind_int64(statement, position, number)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw IndexError.queryFailed(message: lastError)
        }
    }

    private var lastError: String {
        guard let db else { return "SQLite database is not open." }
        return String(cString: sqlite3_errmsg(db))
    }
}

private enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int64)
}

private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
    guard let cString = sqlite3_column_text(statement, index) else {
        return ""
    }
    return String(cString: cString)
}

enum IndexError: LocalizedError {
    case openFailed(message: String)
    case queryFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "Could not open context index: \(message)"
        case .queryFailed(let message):
            "Context index failed: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
