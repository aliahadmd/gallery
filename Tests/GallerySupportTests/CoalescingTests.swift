import Foundation
import Testing
@testable import GallerySupport

/// Sleep parks until the test opens the gate, so "one emit per interval" is proven by tick counts
/// rather than wall-clock waiting.
actor GateClock: CoalescingClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    func sleep(for interval: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sleepers.append(continuation)
        }
    }

    func advance() {
        let waiting = sleepers
        sleepers.removeAll()
        for continuation in waiting { continuation.resume(returning: ()) }
    }
}

@Suite struct CoalescingTests {
    @Test func emitsLeadingValueThenCollapsesToTheNewest() async throws {
        let clock = GateClock()
        let coalescer = Coalescing<String>(interval: .seconds(1), clock: clock)
        let (source, sink) = AsyncStream<String>.makeStream()
        let output = coalescer.attach(source)
        var iterator = output.makeAsyncIterator()

        sink.yield("a")
        #expect(await iterator.next() == "a")

        sink.yield("b")
        sink.yield("c")
        await clock.advance()
        var newest = await iterator.next()
        if newest == "b" {
            // Only b had reached the buffer when the pump woke; c must still come out.
            await clock.advance()
            newest = await iterator.next()
        }
        #expect(newest == "c")

        sink.finish()
        await clock.advance()
        #expect(await iterator.next() == nil)
    }

    @Test func finishingTheSourceNeverDropsTheLastValue() async throws {
        let clock = GateClock()
        let coalescer = Coalescing<String>(interval: .seconds(1), clock: clock)
        let (source, sink) = AsyncStream<String>.makeStream()
        let output = coalescer.attach(source)
        var iterator = output.makeAsyncIterator()

        sink.yield("a")
        #expect(await iterator.next() == "a")

        sink.yield("final-progress")
        sink.finish()
        await clock.advance()
        #expect(await iterator.next() == "final-progress")
        await clock.advance()
        #expect(await iterator.next() == nil)
    }

    @Test func aLongBurstCollapsesToTheNewestValue() async throws {
        let clock = GateClock()
        let coalescer = Coalescing<Int>(interval: .seconds(1), clock: clock)
        let (source, sink) = AsyncStream<Int>.makeStream()
        let output = coalescer.attach(source)
        var iterator = output.makeAsyncIterator()

        sink.yield(0)
        #expect(await iterator.next() == 0)

        for value in 1..<10_000 { sink.yield(value) }
        sink.finish()

        // The bridge never sleeps, so this short wait lets it drain the burst into the newest-1
        // buffer; it proves task progress, not throttle timing. Only the pump can then wake, and
        // the single buffered value it finds is the newest one.
        try await Task.sleep(for: .milliseconds(200))

        var emitted: [Int] = []
        var previous = 0
        for _ in 0..<1_000 {
            await clock.advance()
            guard let value = await iterator.next() else { break }
            #expect(value > previous, "emissions must move forward")
            previous = value
            emitted.append(value)
        }
        #expect(emitted.count < 1_000, "the burst collapsed")
        #expect(emitted.last == 9_999, "the last value must survive the collapse")
    }

    @Test func outputFinishesWhenSourceFinishesOnTheSystemClock() async throws {
        let coalescer = Coalescing<Int>(interval: .milliseconds(5))
        let (source, sink) = AsyncStream<Int>.makeStream()
        let output = coalescer.attach(source)
        let collector = Task { () -> [Int] in
            var values: [Int] = []
            for await value in output { values.append(value) }
            return values
        }
        for value in 0..<200 { sink.yield(value) }
        sink.finish()

        let values = await collector.value
        #expect(!values.isEmpty)
        #expect(values.last == 199)
        #expect(values.count < 200, "a burst must not pass through value-for-value")
    }

    @Test func tearingDownTheOutputStreamCancelsTheSource() async throws {
        let clock = GateClock()
        let coalescer = Coalescing<Int>(interval: .seconds(1), clock: clock)
        let (source, sink) = AsyncStream<Int>.makeStream()
        let terminated = TerminationRecorder()
        sink.onTermination = { _ in
            Task { await terminated.record() }
        }

        let consumer = Task {
            for await _ in coalescer.attach(source) {}
        }
        sink.yield(1)
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value
        try await Task.sleep(for: .milliseconds(100))
        #expect(await terminated.didTerminate)
    }
}

actor TerminationRecorder {
    private(set) var didTerminate = false
    func record() { didTerminate = true }
}
