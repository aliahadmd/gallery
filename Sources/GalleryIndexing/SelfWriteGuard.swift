import Foundation
import GalleryDomain

/// Remembers that the app itself just wrote a file, so the folder watcher does not treat that write as a
/// user edit and walk the whole folder two seconds later.
///
/// A guard shared by the coordinator and the editing service, rather than a flag on either: the write and
/// the watcher are two actors, and the only thing they share is this question.
public final class SelfWriteGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var lastWrite: Date?
    private let duration: TimeInterval

    public init(duration: TimeInterval = Limits.selfWriteWindow) {
        self.duration = duration
    }

    public func note(at date: Date = Date()) {
        lock.withLock { lastWrite = date }
    }

    public func shouldIgnore(at date: Date = Date()) -> Bool {
        lock.withLock {
            guard let lastWrite else { return false }
            let age = date.timeIntervalSince(lastWrite)
            return age >= 0 && age < duration
        }
    }
}
