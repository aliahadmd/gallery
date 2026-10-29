import Foundation
import CoreServices

/// Tells a coordinator that a folder it indexed has changed on disk.
///
/// FSEvents rather than a timer: a library of 100k files cannot afford a full stat walk every minute, and a
/// user who drops a photo into a folder expects to see it without asking. The watcher reports *that*
/// something changed and nothing else — deciding what changed is pass A's job, and a second walker with its
/// own opinions about skip rules is how two halves of an indexer start disagreeing.
///
/// Events arrive on a private queue; the callback is expected to hop somewhere safe.
public final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let latency: CFTimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.gallery.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    /// - Parameter latency: how long the kernel may coalesce events. One second turns a folder copy of a
    ///   thousand files into one wake-up instead of a thousand.
    public init(path: String, latency: CFTimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func fire() {
        onChange()
    }
}
