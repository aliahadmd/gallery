import Foundation

/// Blocking framework work, kept off the cooperative pool.
///
/// An ImageIO decode holds its thread for tens of milliseconds, and the cooperative pool has exactly
/// `activeProcessorCount` threads in it: put a scan's worth of decodes there and every other task in the app
/// — including the one painting the grid — queues behind a JPEG. A GCD queue gives that work a thread that
/// is not the pool's; the semaphore gives it a bound the queue cannot, because a concurrent queue would run
/// all hundred requests at once. One semaphore shared by every caller is what makes the bound apply to the
/// process rather than per feature.
public struct BlockingLane: Sendable {
    public enum Outcome<T: Sendable>: Sendable {
        case completed(T)
        /// The waiting task was cancelled before it got a permit, so nothing ran. A lane is always allowed to
        /// drop cancelled work — that is the entire point of the queue in front of the semaphore.
        case cancelled
    }

    private let queue: DispatchQueue
    private let semaphore: AsyncSemaphore

    public init(label: String, qos: DispatchQoS = .utility, semaphore: AsyncSemaphore) {
        // Concurrent on purpose: the width is the semaphore's business, and a serial queue would silently cap
        // every lane at one decode. `.workItem` draining is what keeps CoreGraphics' autoreleased objects
        // from piling up on a long-lived scan.
        self.queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent,
                                   autoreleaseFrequency: .workItem)
        self.semaphore = semaphore
    }

    public var availablePermits: Int { semaphore.availablePermits }

    public var waiterCount: Int { semaphore.waiterCount }

    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> Outcome<T> {
        do {
            try await semaphore.acquire()
        } catch {
            return .cancelled
        }
        defer { semaphore.release() }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: .completed(work())) }
        }
    }

    /// The bound without the thread.
    ///
    /// `AVURLAsset`'s loads are already async, so hopping to a dispatch queue would pay a switch to buy
    /// nothing; what this kind of work still needs is a ceiling on how many assets are open at once, because
    /// that is the number the disk and the media daemon pay for. Nil means the caller was cancelled while
    /// waiting for a permit.
    public func bounded<T: Sendable>(_ work: @Sendable () async -> T) async -> T? {
        do {
            try await semaphore.acquire()
        } catch {
            return nil
        }
        defer { semaphore.release() }
        return await work()
    }
}

extension BlockingLane {
    /// The lane every still-image decode shares, bounded like the indexer's other image work.
    public static func imageBaking(label: String = "app.gallery.imageio") -> BlockingLane {
        BlockingLane(label: label, semaphore: .imageDecode())
    }
}
