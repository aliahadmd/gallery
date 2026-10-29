import Foundation
import Testing
@testable import GallerySQLite

/// A schema script with the shape that actually broke: a trigger body containing semicolons. Splitting on
/// `;` is the obvious implementation and it is wrong, so the driver has to cut a script the way SQLite
/// reads it — one compiled statement at a time, following the tail pointer.
private let script = """
CREATE TABLE t(id INTEGER PRIMARY KEY, x INTEGER NOT NULL, label TEXT);
CREATE TABLE audit(n INTEGER);

CREATE TRIGGER t_after_insert AFTER INSERT ON t BEGIN
  INSERT INTO audit(n) VALUES (new.x);
  INSERT INTO audit(n) VALUES (-new.x);
END;

INSERT INTO t(x, label) VALUES (7, 'seven');
INSERT INTO t(x, label) VALUES (8, 'eight');
"""

private struct StepFailure: Error {}

private func baseline(_ handle: SQLiteHandle) throws {
    try handle.exec("CREATE TABLE photo(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    try handle.exec("INSERT INTO photo(id, name) VALUES (1, 'IMG_1.JPG')")
}

@Suite("Schema scripts and the migration ladder")
struct MigrationTests {
    @Test("Every statement in a script runs, including a multi-statement trigger body")
    func scriptRunsWhole() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec(script)

        #expect(try handle.query("SELECT id FROM t").count == 2)
        // Two audit rows per insert is only possible if the trigger body survived the split intact.
        #expect(try handle.firstValueOrThrow("SELECT COUNT(*) FROM audit").int64OrZero == 4)
        #expect(try handle.firstValueOrThrow("SELECT COUNT(*) FROM sqlite_master").int64OrZero == 3)
    }

    @Test("A comment-only script compiles to nothing and is not an error")
    func commentsOnly() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        try handle.exec("""
        -- Nothing executable here.
        -- A trailing comment with a ; inside it must not become a statement.
        """)
        #expect(try handle.query("SELECT name FROM sqlite_master").isEmpty)
    }

    @Test("A fresh database gets the newest version, not the first step")
    func createsAtNewest() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        let ladder = [
            Migration(version: 1, name: "v1", up: baseline),
            Migration(version: 2, name: "v2", up: { try $0.exec("ALTER TABLE photo ADD COLUMN size INTEGER") }),
        ]
        let outcome = try Migrator.migrate(handle, migrations: ladder, fresh: baseline)

        #expect(outcome == .created)
        // The `fresh` script is the *current* schema, so version 1's step must not run on top of it —
        // that is why creation jumps straight to the top of the ladder.
        #expect(try handle.userVersion() == 2)
    }

    @Test("Reopening a current database changes nothing")
    func unchangedOnReopen() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let first = try SQLiteHandle.open(path: path, kind: .readWrite)
        _ = try Migrator.migrate(first, migrations: [Migration(version: 1, name: "v1", up: baseline)],
                                 fresh: baseline)

        let again = try SQLiteHandle.open(path: path, kind: .readWrite)
        #expect(try Migrator.migrate(again, migrations: [
            Migration(version: 1, name: "v1", up: baseline)
        ], fresh: baseline) == .unchanged)
        // `baseline` creates `photo`, so had creation re-run it the second open would have thrown.
        #expect(try again.query("SELECT name FROM photo").count == 1)
    }

    @Test("A library two versions behind walks every step and keeps its rows")
    func stepsForward() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let created = try SQLiteHandle.open(path: path, kind: .readWrite)
        _ = try Migrator.migrate(created, migrations: [Migration(version: 1, name: "v1", up: baseline)],
                                 fresh: baseline)

        let opened = try SQLiteHandle.open(path: path, kind: .readWrite)
        let outcome = try Migrator.migrate(
            opened,
            migrations: [
                Migration(version: 1, name: "v1", up: baseline),
                Migration(version: 2, name: "v2 widens", up: {
                    try $0.exec("ALTER TABLE photo ADD COLUMN size INTEGER NOT NULL DEFAULT 0")
                }),
                Migration(version: 3, name: "v3 backfills", up: {
                    try $0.exec("UPDATE photo SET size = 4096 WHERE name = 'IMG_1.JPG'")
                }),
            ],
            fresh: baseline
        )

        #expect(outcome == .migrated(from: 1, to: 3, steps: ["v2 widens", "v3 backfills"]))
        #expect(try opened.userVersion() == 3)
        let row = try #require(opened.query("SELECT name, size FROM photo").first)
        #expect(try row.string(named: "name") == "IMG_1.JPG")
        #expect(try row.int64(named: "size") == 4096)
    }

    @Test("A step that throws leaves the version and the data exactly where they were")
    func failingStepRollsBack() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let created = try SQLiteHandle.open(path: path, kind: .readWrite)
        _ = try Migrator.migrate(created, migrations: [Migration(version: 1, name: "v1", up: baseline)],
                                 fresh: baseline)

        let opened = try SQLiteHandle.open(path: path, kind: .readWrite)
        #expect(throws: StepFailure.self) {
            try Migrator.migrate(
                opened,
                migrations: [
                    Migration(version: 1, name: "v1", up: baseline),
                    Migration(version: 2, name: "v2 half-does", up: { handle in
                        try handle.exec("CREATE TABLE scratch(x INTEGER)")
                        throw StepFailure()
                    }),
                ],
                fresh: baseline
            )
        }

        #expect(try opened.userVersion() == 1, "the version marker is the last write in the transaction")
        #expect(try opened.query("SELECT name FROM sqlite_master WHERE name = 'scratch'").isEmpty,
                "DDL is transactional in SQLite, so a rolled-back migration really is undone")
        #expect(try opened.query("SELECT name FROM photo").count == 1)
    }

    @Test("A database from a newer build is refused, not repaired")
    func refusesNewerDatabase() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let future = try SQLiteHandle.open(path: path, kind: .readWrite)
        try future.exec("CREATE TABLE photo(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try future.setUserVersion(7)

        let opened = try SQLiteHandle.open(path: path, kind: .readWrite)
        do {
            try Migrator.migrate(opened, migrations: [
                Migration(version: 1, name: "v1", up: baseline),
                Migration(version: 2, name: "v2", up: { _ in }),
            ], fresh: baseline)
            Issue.record("a newer database must be refused, not walked backwards")
        } catch let error as SQLiteError {
            guard case .downgradeDetected(let found, let supported) = error else {
                Issue.record("expected .downgradeDetected, got \(error)")
                return
            }
            #expect(found == 7)
            #expect(supported == 2, "the message has to name what this build can actually read")
        }
        // Refusing has to be the whole behaviour: the user's rows are still there for a read-only open.
        #expect(try opened.query("SELECT name FROM sqlite_master WHERE name = 'photo'").count == 1)
    }

    @Test("The outcome text is what a launch log should say")
    func outcomeDescribesItself() throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let handle = try SQLiteHandle.open(path: path, kind: .readWrite)
        #expect(try Migrator.migrate(handle, migrations: [Migration(version: 1, name: "v1", up: baseline)],
                                     fresh: baseline).description == "schema created")
        #expect(MigrationOutcome.migrated(from: 1, to: 3, steps: ["v2", "v3"]).description
                == "schema 1 → 3: v2, v3")
    }
}
