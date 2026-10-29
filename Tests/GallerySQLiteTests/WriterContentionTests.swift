import Foundation
import SQLite3
import Testing
@testable import GallerySQLite

/// Two concurrent connections in a test need the same thing the catalog gives them in production: one actor
/// per `SQLiteHandle`, because a handle is deliberately not `Sendable`.
///
/// `busyTimeout: 0` is the test setting, not the shipped one. SQLite's own timeout would sleep inside
/// `sqlite3_step` and hide the retry ladder in `Transactions.swift`; with zero the driver answers `SQLITE_BUSY`
/// immediately and the ladder is what is under test.
private actor Connection {
    let handle: SQLiteHandle

    init(path: String, busyTimeout: Int) throws {
        handle = try SQLiteHandle.open(path: path, kind: .readWrite, pragmas: [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA busy_timeout=\(busyTimeout)",
        ])
        try handle.exec("CREATE TABLE IF NOT EXISTS t(x INTEGER NOT NULL)")
    }

    /// Holds the write lock across an `await`, which is the state a second Gallery process is in when it
    /// loses the race.
    func holdWriteLock() throws { try handle.exec("BEGIN IMMEDIATE") }
    func commit() throws { try handle.exec("COMMIT") }

    func insert(_ x: Int) throws {
        try handle.exec("INSERT INTO t(x) VALUES (?)", [.integer(Int64(x))])
    }

    func insertWithRetry(_ x: Int, maxRetries: Int = LockBackoff.maximumAttempts) async throws {
        let handle = self.handle
        try await retry(maxRetries: maxRetries) {
            try handle.attemptWrite {
                try handle.exec("INSERT INTO t(x) VALUES (?)", [.integer(Int64(x))])
            }
        }
    }

    /// Ten rows per transaction: the batch granularity the catalog actually writes at.
    func insertSweep(from start: Int, through end: Int) async throws {
        let handle = self.handle
        var offset = start
        while offset <= end {
            let chunk = offset..<min(offset + 10, end + 1)
            try await retry(maxRetries: LockBackoff.maximumAttempts) {
                try handle.attemptWrite {
                    for x in chunk { try handle.exec("INSERT INTO t(x) VALUES (?)", [.integer(Int64(x))]) }
                }
            }
            offset += 10
        }
    }

    /// The ladder, owned by the actor that owns the handle. `attemptWrite` is synchronous and answers
    /// "committed" or "busy"; only the waiting is async, and a handle must never be held across a
    /// suspension by anything other than its own actor.
    private func retry<T>(maxRetries: Int, _ attempt: () throws -> WriteOutcome<T>) async throws -> T {
        var burned = 0
        while true {
            switch try attempt() {
            case .committed(let value):
                return value
            case .busy:
                guard burned < maxRetries else { throw SQLiteError.busy(retries: burned) }
                try await Task.sleep(for: LockBackoff.delay(afterAttempt: burned) + LockBackoff.jitter())
                burned += 1
            }
        }
    }

    func count() throws -> Int { Int(try handle.firstValueOrThrow("SELECT COUNT(*) FROM t").int64OrZero) }
    func distinctCount() throws -> Int {
        Int(try handle.firstValueOrThrow("SELECT COUNT(DISTINCT x) FROM t").int64OrZero)
    }

    /// A batch that throws half-way through, which is the shape of a per-file failure inside a 500-row write.
    func failingBatch() throws {
        try handle.write {
            try handle.exec("INSERT INTO t(x) VALUES (2)")
            throw Rollback()
        }
    }
}

private actor Snapshot {
    let handle: SQLiteHandle

    init(path: String) throws {
        handle = try SQLiteHandle.open(path: path, kind: .readOnly)
    }

    func count() throws -> Int { Int(try handle.firstValueOrThrow("SELECT COUNT(*) FROM t").int64OrZero) }
}

private func busyCode(of body: () async throws -> Void) async -> Int32? {
    do {
        try await body()
        return nil
    } catch let error as SQLiteError {
        return error.resultCode
    } catch {
        Issue.record("expected a SQLiteError, got \(error)")
        return nil
    }
}

@Suite("Two processes, one database file")
struct WriterContentionTests {
    @Test("A writer that loses the lock is turned away with SQLITE_BUSY, not made to wait")
    func loserIsTurnedAway() async throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let holder = try Connection(path: path, busyTimeout: 0)
        let contender = try Connection(path: path, busyTimeout: 0)
        try await holder.holdWriteLock()

        let code = await busyCode(of: { try await contender.insert(1) })
        #expect(code == SQLITE_BUSY, "anything else and the retry ladder in Transactions.swift has nothing to catch")

        try await holder.commit()
        try await contender.insert(2)
        #expect(try await contender.count() == 1)
    }

    @Test("The retry ladder rides out a lock the other process is still holding")
    func retrySucceedsWhenTheLockIsReleased() async throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let holder = try Connection(path: path, busyTimeout: 0)
        let contender = try Connection(path: path, busyTimeout: 0)
        try await holder.holdWriteLock()

        let pending = Task { try await contender.insertWithRetry(42) }
        try await Task.sleep(for: .milliseconds(5))
        try await holder.commit()
        try await pending.value

        #expect(try await contender.count() == 1)
        #expect(try await holder.count() == 1)
    }

    @Test("A spent retry budget is an error the caller can act on")
    func exhaustedBudgetReportsBusy() async throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let holder = try Connection(path: path, busyTimeout: 0)
        let contender = try Connection(path: path, busyTimeout: 0)
        try await holder.holdWriteLock()

        do {
            try await contender.insertWithRetry(7, maxRetries: 1)
            Issue.record("expected the retry budget to run out")
        } catch let error as SQLiteError {
            guard case .busy(let retries) = error else {
                Issue.record("expected .busy, got \(error)")
                return
            }
            #expect(retries == 1)
        }
        #expect(try await contender.count() == 0, "a failed batch leaves nothing half-written")
        // Releasing here rather than in a `defer`, because a `defer` cannot await the actor.
        try await holder.commit()
    }

    @Test("Independent writers converge without losing or duplicating a row")
    func concurrentBatchesConverge() async throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let first = try Connection(path: path, busyTimeout: 0)
        let second = try Connection(path: path, busyTimeout: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await first.insertSweep(from: 1, through: 50) }
            group.addTask { try await second.insertSweep(from: 51, through: 100) }
            try await group.waitForAll()
        }

        #expect(try await first.count() == 100)
        // Distinct values only: a retried batch that half-committed would show up as a duplicate here.
        #expect(try await first.distinctCount() == 100)
    }
}

@Suite("A scan does not stall the grid")
struct WALSnapshotTests {
    @Test("The reader sees the last commit, never the transaction in progress")
    func uncommittedWritesAreInvisible() async throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let writer = try Connection(path: path, busyTimeout: 0)
        try await writer.insert(1)
        let reader = try Snapshot(path: path)
        #expect(try await reader.count() == 1)

        try await writer.holdWriteLock()
        try await writer.insert(2)
        #expect(try await reader.count() == 1, "a batch mid-flight must not paint half a library")

        try await writer.commit()
        // WAL readers start a fresh read transaction per statement, so the next page load sees the new row
        // without anyone reopening the connection or re-running a migration.
        #expect(try await reader.count() == 2)
    }

    @Test("A rolled-back batch leaves the reader with exactly what it had")
    func rollbackIsInvisibleToo() async throws {
        let (path, cleanup) = temporaryDatabase()
        defer { cleanup() }

        let writer = try Connection(path: path, busyTimeout: 0)
        try await writer.insert(1)
        let reader = try Snapshot(path: path)

        await #expect(throws: Rollback.self) { try await writer.failingBatch() }
        #expect(try await reader.count() == 1)
        #expect(try await writer.count() == 1)
    }
}

private struct Rollback: Error {}

@Suite("The retry schedule")
struct LockBackoffTests {
    @Test("20 ms doubling to a 320 ms ceiling")
    func schedule() {
        let ladder = (0..<6).map { LockBackoff.delay(afterAttempt: $0) }
        #expect(ladder == [20, 40, 80, 160, 320, 320].map(Duration.milliseconds),
                "the last two share a value because the ceiling clamps")
    }

    @Test("A nonsense attempt count still yields a real delay")
    func clampedAtBothEnds() {
        #expect(LockBackoff.delay(afterAttempt: -1) == .milliseconds(20))
        #expect(LockBackoff.delay(afterAttempt: .max) == .milliseconds(320))
    }

    @Test("Jitter widens the ladder without inverting it")
    func jitter() {
        for _ in 0..<200 {
            let jitter = LockBackoff.jitter()
            #expect(jitter >= .zero && jitter <= .milliseconds(20))
        }
    }
}
