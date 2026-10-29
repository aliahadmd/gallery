import Foundation
import Testing
@testable import GallerySupport

actor ConcurrencyCounter {
    private(set) var peak = 0
    private(set) var completions = 0
    private var active = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func leave() {
        active -= 1
        completions += 1
    }
}

actor TagLog {
    private(set) var tags: [String] = []
    func record(_ tag: String) { tags.append(tag) }
}

/// Poll until `semaphore` reports `expected` parked tasks. A test that asserts on queue order has to know
/// the order was actually established, and "the task was created 100 ms ago" is not that knowledge.
private func parked(_ expected: Int, in semaphore: AsyncSemaphore) async throws {
    for _ in 0..<250 {
        if semaphore.waiterCount == expected { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("never reached \(expected) parked waiter(s); saw \(semaphore.waiterCount)")
}

/// The semaphore is what keeps a 100k-file scan from saturating the cooperative thread pool, so its
/// concurrency accounting and cancellation behaviour have to be proven, not assumed.
@Suite struct AsyncSemaphoreTests {
    @Test func neverExceedsPermitCount() async throws {
        let semaphore = AsyncSemaphore(value: 3)
        let counter = ConcurrencyCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<60 {
                group.addTask {
                    guard (try? await semaphore.acquire()) != nil else { return }
                    await counter.enter()
                    await counter.leave()
                    semaphore.release()
                }
            }
        }

        let peak = await counter.peak
        let completions = await counter.completions
        #expect(peak <= 3)
        #expect(completions == 60)
    }

    /// The property is "a permit goes to whoever decided to wait first", which is not the same as whoever
    /// registered first — so the waiters are parked one at a time, watching `waiterCount`, before any
    /// release happens. Each waiter hands its permit back when it is done, so the second wake-up is caused
    /// by the first one finishing rather than by a sleep that happens to be long enough.
    @Test func waitersAreServedInOrder() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.acquire()
        let log = TagLog()

        func wait(_ tag: String) -> Task<Void, any Error> {
            Task {
                try await semaphore.acquire()
                await log.record(tag)
                semaphore.release()
            }
        }

        let first = wait("first")
        try await parked(1, in: semaphore)
        let second = wait("second")
        try await parked(2, in: semaphore)

        semaphore.release()
        try await first.value
        try await second.value

        #expect(await log.tags == ["first", "second"])
        #expect(semaphore.availablePermits == 1, "the permit the test borrowed comes back and no more")
    }

    @Test func cancelledWaiterLeavesTheBudgetIntact() async throws {
        let semaphore = AsyncSemaphore(value: 1)
        try await semaphore.acquire()

        let waiter = Task { try await semaphore.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            Issue.record("expected the queued acquire to be cancelled")
        } catch is AsyncSemaphore.Failure {
            // expected
        }

        // Releasing the one permit we still hold must wake nobody but the next acquirer; a leaked
        // reservation would leave this hanging forever instead.
        semaphore.release()
        let afterRelease = semaphore.availablePermits
        #expect(afterRelease == 1)

        try await Task { try await semaphore.acquire() }.value
        let afterAcquire = semaphore.availablePermits
        #expect(afterAcquire == 0)
    }

    /// Regression guard for the deadlock where cancellation arrives after `acquire()` decides to
    /// enqueue but before the continuation is registered: the marker has to be remembered so the
    /// waiter can be failed the moment it lands.
    @Test func cancellationAroundEnqueueAlwaysThrowsAndNeverLeaksAPermit() async throws {
        for iteration in 0..<40 {
            let semaphore = AsyncSemaphore(value: 2)
            let task = Task { try await semaphore.acquire() }
            if iteration.isMultiple(of: 2) {
                task.cancel()  // may beat the isCancelled check entirely
            } else {
                try await Task.sleep(for: .microseconds(50))
                task.cancel()  // lands mid-registration far more often
            }
            do {
                try await task.value
                // Allowed only if the acquire genuinely completed before cancellation.
                let permits = semaphore.availablePermits
                #expect(permits <= 1)
                semaphore.release()
            } catch is AsyncSemaphore.Failure {
                let permits = semaphore.availablePermits
                #expect(permits == 2, "a cancelled acquire must return its permit")
            }
        }
    }

    @Test func zeroPermitSemaphoreStillBalances() async throws {
        let semaphore = AsyncSemaphore(value: 0)
        let acquired = Task { try await semaphore.acquire() }
        try await Task.sleep(for: .milliseconds(30))
        let before = semaphore.availablePermits
        #expect(before == 0)
        semaphore.release()
        try await acquired.value
        let after = semaphore.availablePermits
        #expect(after == 0)  // handed straight to the waiter, not left pooled
    }
}
