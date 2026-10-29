import Foundation
import Testing
@testable import GalleryIndexing

/// A one-way latch the FSEvents callback can set from its own queue.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }

    func set() { lock.withLock { flag = true } }
}

@Suite("Folder watching")
struct FolderWatcherTests {
    @Test("A file written into a watched folder wakes the watcher")
    func writeWakesTheWatcher() async throws {
        let tree = try FixtureTree()
        defer { tree.cleanup() }

        let fired = Flag()
        let watcher = FolderWatcher(path: tree.root.path, latency: 0.1) { fired.set() }
        watcher.start()
        defer { watcher.stop() }

        try tree.file("dropped.jpg")

        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, !fired.value {
            try await clock.sleep(for: .milliseconds(50))
        }
        #expect(fired.value, "a write in a watched folder has to reach the app")
    }

    @Test("A stopped watcher stays quiet")
    func stoppedWatcherDoesNotFire() async throws {
        let tree = try FixtureTree()
        defer { tree.cleanup() }

        let fired = Flag()
        let watcher = FolderWatcher(path: tree.root.path, latency: 0.1) { fired.set() }
        watcher.start()
        watcher.stop()

        try tree.file("ignored.jpg")
        try await SuspendingClock().sleep(for: .milliseconds(600))
        #expect(!fired.value)
    }
}
