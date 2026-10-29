import Foundation

/// A counting semaphore. The Swift standard library has none, and the indexer needs one for a reason
/// that `withTaskGroup(of:boundingSize:)` alone cannot satisfy: the interactive lane (a cell the user
/// just scrolled into view) must be able to interleave with — and take priority over — a background
/// scan that is already saturating its group width. Group size bounds a single group; a semaphore bounds
/// the shared resource across all of them.
///
/// Deliberately a lock-guarded class rather than an actor: `release()` has to be callable from `defer`
/// and from a task cancellation handler, neither of which can `await`. Continuations are always resumed
/// outside the lock, so a waiter's first instructions can't run while another task holds it.
public final class AsyncSemaphore: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case cancelled
    }

    private struct Waiter {
        var id: UInt64
        var continuation: CheckedContinuation<Void, Error>
    }

    private enum Acquisition {
        case granted
        case enqueue(id: UInt64)
    }

    private let lock = NSLock()
    private var available: Int
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    /// Cancellation that arrives after `acquire()` decided to wait but before the continuation is
    /// registered. The id is remembered here so `register` can fail the waiter immediately instead of
    /// parking it behind a permit nobody will release.
    private var cancelledBeforeRegistration: Set<UInt64> = []

    public init(value: Int) {
        precondition(value >= 0, "a semaphore cannot start with negative permits")
        available = value
    }

    public var availablePermits: Int {
        lock.withLock { available }
    }

    /// How many tasks are parked. Saturation is a different signal from busy: the indexer's HUD and its
    /// tests both need to tell "all permits handed out" apart from "all permits handed out *and* work
    /// queued behind them".
    public var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    /// Waits for a permit. Throws `Failure.cancelled` if the calling task is cancelled; in that case no
    /// permit is consumed and no waiter is left registered.
    public func acquire() async throws {
        if Task.isCancelled { throw Failure.cancelled }

        let decision = lock.withLock { () -> Acquisition in
            if available > 0 {
                available -= 1
                return .granted
            }
            let id = nextWaiterID
            nextWaiterID += 1
            return .enqueue(id: id)
        }

        guard case .enqueue(let id) = decision else { return }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                switch register(id, continuation) {
                case .parked: break
                case .granted: continuation.resume(returning: ())
                case .cancelled: continuation.resume(throwing: Failure.cancelled)
                }
            }
        } onCancel: {
            self.cancel(id)
        }
    }

    /// Hands a permit to the oldest waiter, or banks it if nobody is waiting.
    public func release() {
        let waiter = lock.withLock { () -> Waiter? in
            if waiters.isEmpty {
                available += 1
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.continuation.resume(returning: ())
    }

    public func withPermit<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private enum Registration {
        case parked
        case granted
        case cancelled
    }

    private func register(_ id: UInt64, _ continuation: CheckedContinuation<Void, Error>) -> Registration {
        lock.withLock { () -> Registration in
            if cancelledBeforeRegistration.remove(id) != nil {
                return .cancelled
            }
            // A permit can have been banked between the decision to wait and this registration; take it
            // rather than queueing behind work that would then have nowhere to go.
            if available > 0 {
                available -= 1
                return .granted
            }
            // Ordered by the *decision*, not by arrival at this method: `acquire()` learns the permit is
            // gone under the lock, then releases it to register the continuation, and two tasks can cross
            // over in between. Appending in registration order would let a background decode overtake an
            // interactive request that queued in front of it, which is the one property this class exists
            // to give the indexer. Scanning from the back because the array is nearly sorted already.
            var position = waiters.count
            while position > 0, waiters[position - 1].id > id { position -= 1 }
            waiters.insert(Waiter(id: id, continuation: continuation), at: position)
            return .parked
        }
    }

    private func cancel(_ id: UInt64) {
        let waiter = lock.withLock { () -> Waiter? in
            guard let position = waiters.firstIndex(where: { $0.id == id }) else {
                cancelledBeforeRegistration.insert(id)
                // A waiter that was already served its permit also lands here, so the markers are dead
                // weight unless pruned. Only ancient ids are dropped, which keeps the genuine
                // cancel-before-registration window — microseconds wide — recoverable.
                if cancelledBeforeRegistration.count > 4096 {
                    let cutoff = nextWaiterID &- 4096
                    cancelledBeforeRegistration = cancelledBeforeRegistration.filter { $0 >= cutoff }
                }
                return nil
            }
            return waiters.remove(at: position)
        }
        waiter?.continuation.resume(throwing: Failure.cancelled)
    }
}

extension AsyncSemaphore {
    /// Permit counts sized for the lanes the indexer runs. Enumeration and `AVURLAsset` loads are both
    /// disk-latency bound, and pushing more parallelism at a spinning platter or an SMB share makes it
    /// slower, not faster — hence the fractions of the CPU count rather than the CPU count itself.
    public static var activeProcessorCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    public static func enumeration() -> AsyncSemaphore {
        AsyncSemaphore(value: min(8, max(2, activeProcessorCount / 2)))
    }

    public static func imageDecode() -> AsyncSemaphore {
        AsyncSemaphore(value: activeProcessorCount)
    }

    public static func videoRead() -> AsyncSemaphore {
        AsyncSemaphore(value: max(2, activeProcessorCount / 4))
    }
}
