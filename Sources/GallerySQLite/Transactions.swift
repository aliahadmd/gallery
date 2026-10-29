import Foundation
import SQLite3

/// Transaction retry, split in two because of one Swift 6 rule: `SQLiteHandle` is deliberately not
/// `Sendable` — its actor is the isolation boundary — so an `async` method *on the handle* cannot hold a
/// closure over it across a suspension point. The compiler says so, and it is right: two tasks could both
/// be parked inside that method on one connection.
///
/// So the handle answers one *synchronous* attempt, and whoever owns the handle (the actor) does the
/// waiting. `LockBackoff` is the schedule; `SQLiteHandle.attemptWrite` is the transaction.
extension SQLiteHandle {
    /// Run `body` inside one `BEGIN IMMEDIATE` transaction and classify the outcome without ever awaiting.
    ///
    /// Lock contention is a `busy` result rather than a thrown error because it is not the caller's
    /// mistake — it is another process holding the write lock, which is a reason to try again later.
    /// Everything else (constraint violations, I/O, SQL bugs) throws, because retrying those would either
    /// loop forever or swallow a real failure.
    public func attemptWrite<T>(_ body: () throws -> T) throws -> WriteOutcome<T> {
        do {
            return .committed(try write(body))
        } catch let error as SQLiteError where error.isLockContention {
            return .busy
        }
    }
}

public enum WriteOutcome<T> {
    case committed(T)
    /// The write lock belonged to someone else. `LockBackoff` says when to ask again.
    case busy
}

/// 20 ms growing to 320 ms with jitter, so two Gallery processes that both woke from a folder event do not
/// retry in lockstep. Jitter is what makes the ladder converge instead of synchronising the contention.
public enum LockBackoff {
    /// Retries after the first attempt. Five of them span ~1 s of waiting, which is longer than a
    /// 500-row catalog batch takes to commit.
    public static let maximumAttempts = 5
    /// The clamp below is the ceiling: 20 ms doubled four steps is 320 ms.
    static let firstDelayMilliseconds = 20

    /// How long to wait before attempt number `attempt`, zero-based: 20, 40, 80, 160, 320 ms.
    /// Clamping the exponent keeps a negative or absurd `attempt` from trapping the shift.
    public static func delay(afterAttempt attempt: Int) -> Duration {
        let steps = min(max(attempt, 0), 4)
        return .milliseconds(firstDelayMilliseconds << steps)
    }

    /// Up to 20 ms of extra jitter on top of `delay(afterAttempt:)`.
    public static func jitter() -> Duration { .nanoseconds(Int.random(in: 0...20_000_000)) }
}
