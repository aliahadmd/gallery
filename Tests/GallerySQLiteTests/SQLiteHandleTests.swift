import Foundation
import Testing
@testable import GallerySQLite

func temporaryDatabase() -> (path: String, cleanup: () -> Void) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("gallery-test-\(UUID().uuidString)")
        .path
    return (path, {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    })
}

@Suite struct SQLiteHandleTests {
    @Test func opensAndRunsFTS5WithRanking() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("CREATE VIRTUAL TABLE docs USING fts5(title, body, tokenize='porter unicode61')")
        try handle.exec("INSERT INTO docs(rowid, title, body) VALUES (1, 'Kyoto temple', 'morning light at Fushimi Inari')")
        try handle.exec("INSERT INTO docs(rowid, title, body) VALUES (2, 'Osaka food', 'takoyaki in Dotonbori')")
        try handle.exec("INSERT INTO docs(rowid, title, body) VALUES (3, 'Kyoto garden', 'rock garden at Ryoan-ji')")

        // Snippet column 0 is `title`, which is where the matched term actually lives.
        let rows = try handle.query(
            "SELECT rowid, snippet(docs, 0, '[', ']', '...', 8) AS hit FROM docs WHERE docs MATCH ? ORDER BY bm25(docs)",
            [.text("kyoto")]
        )
        #expect(rows.count == 2)
        let firstID = try #require(rows.first).int64(named: "rowid")
        #expect(firstID == 1 || firstID == 3)
        let snippet = try #require(rows.first).string(named: "hit")
        #expect(snippet.lowercased().contains("kyoto"))
    }

    @Test func journalModeIsWALAndVersionRoundTrips() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        #expect(try handle.firstValueOrThrow("PRAGMA journal_mode").stringValue == "wal")
        try handle.exec("CREATE TABLE t(x INTEGER)")
        try handle.setUserVersion(3)
        #expect(try handle.userVersion() == 3)
    }

    @Test func readOnlyConnectionRefusesWrites() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let writer = try SQLiteHandle.open(path: path, kind: .readWrite)
        try writer.exec("CREATE TABLE t(x INTEGER)")
        try writer.exec("INSERT INTO t VALUES (1)")

        let reader = try SQLiteHandle.open(path: path, kind: .readOnly)
        #expect(reader.kind == .readOnly)
        #expect(throws: SQLiteError.self) {
            try reader.write { try reader.exec("INSERT INTO t VALUES (2)") }
        }
        #expect(try reader.query("SELECT x FROM t").count == 1)
    }

    @Test func transactionRollsBackOnThrow() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("CREATE TABLE t(x INTEGER PRIMARY KEY, y TEXT)")
        struct Boom: Error {}
        do {
            try handle.write {
                try handle.exec("INSERT INTO t VALUES (1, 'kept')")
                throw Boom()
            }
            Issue.record("expected the transaction to rethrow Boom")
        } catch is Boom {
            // expected
        }
        #expect(try handle.query("SELECT x FROM t").isEmpty)
        // The connection must still be usable after a rollback, not stuck inside a transaction.
        try handle.write { try handle.exec("INSERT INTO t VALUES (2, 'fine')") }
        #expect(try handle.query("SELECT x FROM t").count == 1)
    }

    @Test func statementReuseBindsEveryValueType() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("CREATE TABLE v(i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)")
        let insert = try handle.prepare("INSERT INTO v VALUES (?, ?, ?, ?, ?)")
        for index in 0..<3 {
            try insert.bind([
                .integer(Int64(index)),
                .real(Double(index) / 2),
                .text("text \(index) — 京都"),
                .blob([0xFF, 0x00, UInt8(index)]),
                .null,
            ])
            try insert.run()
            insert.reset()
        }

        let rows = try handle.query("SELECT i, r, s, b, n FROM v ORDER BY i")
        #expect(rows.count == 3)
        #expect(try rows[2].string(named: "s") == "text 2 — 京都")
        #expect(try rows[1].blob(named: "b") == [0xFF, 0x00, 1])
        #expect(try rows[0].value(named: "n").isNull)
        #expect(try rows[2].double(named: "r") == 1.0)
    }

    @Test func bindArityMismatchIsCaught() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("CREATE TABLE t(x INTEGER)")
        let statement = try handle.prepare("INSERT INTO t VALUES (?)")
        #expect(throws: SQLiteError.self) { try statement.bind([]) }
        #expect(throws: SQLiteError.self) { try statement.bind([.integer(1), .integer(2)]) }
    }

    @Test func unknownColumnNamesThrow() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("CREATE TABLE t(x INTEGER)")
        try handle.exec("INSERT INTO t VALUES (1)")
        let row = try #require(try handle.query("SELECT x AS the_x FROM t").first)
        #expect(row.index(of: "THE_X") == 0)  // case-insensitive lookup
        #expect(throws: SQLiteError.self) { _ = try row.int64(named: "missing") }
    }

    /// A partially-stepped cursor left open makes the next statement return SQLITE_BUSY. `run(_:)`
    /// must reset on the way out even when the body throws.
    @Test func runResetsEvenOnFailure() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("CREATE TABLE t(x INTEGER NOT NULL)")
        let statement = try handle.prepare("INSERT INTO t VALUES (?)")
        #expect(throws: SQLiteError.self) { try statement.run([.null]) }
        try statement.run([.integer(7)])
        #expect(try handle.query("SELECT x FROM t").count == 1)
    }

    @Test func inMemoryDatabaseWorksForPureQueryTests() throws {
        let handle = try SQLiteHandle.open(path: ":memory:", kind: .readWrite, pragmas: ["PRAGMA foreign_keys=ON"])
        try handle.exec("CREATE TABLE parent(id INTEGER PRIMARY KEY)")
        try handle.exec("CREATE TABLE child(pid INTEGER REFERENCES parent(id) ON DELETE CASCADE)")
        try handle.exec("INSERT INTO parent VALUES (1)")
        try handle.exec("INSERT INTO child VALUES (1)")
        #expect(throws: SQLiteError.self) { try handle.exec("INSERT INTO child VALUES (99)") }
        try handle.exec("DELETE FROM parent WHERE id = 1")
        #expect(try handle.query("SELECT pid FROM child").isEmpty)
    }
}
