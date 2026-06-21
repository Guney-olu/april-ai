#!/usr/bin/env swift
import Foundation
import SQLite3

let dbURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "april-ai-memory-brain-\(UUID().uuidString).sqlite3")
defer { try? FileManager.default.removeItem(at: dbURL) }

var db: OpaquePointer?
guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
    fputs("FAIL could not open sqlite database\n", stderr)
    exit(1)
}
defer { sqlite3_close(db) }

func exec(_ sql: String) {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        fputs("FAIL sqlite exec: \(message)\nSQL: \(sql)\n", stderr)
        exit(1)
    }
}

exec("""
CREATE TABLE memory_items (
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
CREATE TABLE memory_sessions (
  session_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  summary TEXT NOT NULL,
  created_at REAL NOT NULL,
  approved_at REAL
);
CREATE TABLE memory_session_items (
  session_id TEXT NOT NULL,
  memory_id TEXT NOT NULL,
  created_at REAL NOT NULL,
  PRIMARY KEY(session_id, memory_id)
);
""")

let now = Date().timeIntervalSince1970
exec("INSERT INTO memory_sessions VALUES('s1','Swift Refactor','Moved files into domain folders',\(now),\(now));")
exec("INSERT INTO memory_sessions VALUES('s2','Mouse Simplification','Collapsed mouse tools',\(now + 1),\(now + 1));")
exec("INSERT INTO memory_sessions VALUES('empty','Empty Shell','Should never render as a brain card',\(now + 2),\(now + 2));")
exec("INSERT INTO memory_items VALUES('m1','procedural','Use domain folders for source organization.','Source layout','Session s1',0.9,0.7,\(now),\(now),'approved');")
exec("INSERT INTO memory_items VALUES('m2','preference','Prefer one simple mouse movement tool over diagnostic machinery.','Mouse preference','Session s2',0.9,0.8,\(now),\(now),'approved');")
exec("INSERT INTO memory_session_items VALUES('s1','m1',\(now));")
exec("INSERT INTO memory_session_items VALUES('s2','m2',\(now));")
exec("INSERT INTO memory_session_items VALUES('s1','m2',\(now));")

func count(_ sql: String) -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        fputs("FAIL prepare count\n", stderr)
        exit(1)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(statement, 0))
}

guard count("SELECT COUNT(*) FROM memory_session_items WHERE session_id='s1';") == 2 else {
    fputs("FAIL session s1 should have two linked memories\n", stderr)
    exit(1)
}
guard count("SELECT COUNT(DISTINCT memory_id) FROM memory_session_items WHERE session_id IN ('s1','s2');") == 2 else {
    fputs("FAIL multi-session plugin should dedupe shared memories\n", stderr)
    exit(1)
}
guard count("SELECT COUNT(*) FROM memory_sessions ms WHERE NOT EXISTS (SELECT 1 FROM memory_session_items msi WHERE msi.session_id = ms.session_id);") == 1 else {
    fputs("FAIL smoke fixture should include one empty session shell\n", stderr)
    exit(1)
}

exec("DELETE FROM memory_sessions WHERE NOT EXISTS (SELECT 1 FROM memory_session_items WHERE memory_session_items.session_id = memory_sessions.session_id);")
guard count("SELECT COUNT(*) FROM memory_sessions WHERE session_id='empty';") == 0 else {
    fputs("FAIL empty session shell should be pruned\n", stderr)
    exit(1)
}

exec("INSERT INTO memory_items VALUES('merged','preference','Merged memory content.','Merged','Merged 2 memories',0.9,0.8,\(now),\(now),'approved');")
exec("INSERT INTO memory_session_items SELECT DISTINCT session_id, 'merged', \(now) FROM memory_session_items WHERE memory_id IN ('m1','m2');")
exec("DELETE FROM memory_session_items WHERE memory_id IN ('m1','m2');")
exec("DELETE FROM memory_items WHERE id IN ('m1','m2');")

guard count("SELECT COUNT(*) FROM memory_items WHERE id='merged';") == 1 else {
    fputs("FAIL merged memory missing\n", stderr)
    exit(1)
}
guard count("SELECT COUNT(DISTINCT session_id) FROM memory_session_items WHERE memory_id='merged';") == 2 else {
    fputs("FAIL merged memory should retain source session links\n", stderr)
    exit(1)
}

print("PASS: memory brain smoke checks passed.")
