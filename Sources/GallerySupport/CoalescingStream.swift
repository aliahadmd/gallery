import Foundation

public protocol CoalescingClock: Sendable {
    func sleep(for interval: Duration) async throws
}

public struct SystemSuspendingClock: CoalescingClock {
    public init() {}

    public func sleep(for interval: Duration) async throws {
        try await SuspendingClock().sleep(for: interval)
    }
}

public struct Coalescing<Value: Sendable>: Sendable {
    private let interval: Duration
    private let clock: any CoalescingClock

    public init(interval: Duration, clock: any CoalescingClock = SystemSuspendingClock()) {
        self.interval = interval
        self.clock = clock
    }

    /// Two stages: the bridge mirrors the source into a newest-1 buffer, so everything that piles up
    /// while the pump sleeps collapses to the latest value; the pump emits, waits out one interval,
    /// and repeats — at most one emission per interval, and every emitted value is the newest that
    /// had arrived. The buffer delivers its held value before the stream end, so the final update
    /// always goes out: a progress HUD cannot stall at 99%.
    public func attach(_ source: AsyncStream<Value>) -> AsyncStream<Value> {
        let (feed, feedContinuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (output, outputContinuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let interval = self.interval
        let clock = self.clock

        let bridge = Task {
            for await value in source {
                feedContinuation.yield(value)
            }
            feedContinuation.finish()
        }
        let pump = Task {
            for await value in feed {
                outputContinuation.yield(value)
                try? await clock.sleep(for: interval)
            }
            outputContinuation.finish()
        }
        outputContinuation.onTermination = { _ in
            bridge.cancel()
            pump.cancel()
        }
        return output
    }
}
