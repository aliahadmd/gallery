import Foundation
import Observation
import GalleryDomain

/// One running batch action: what it is, how far it got, and which items failed.
///
/// The model owns at most one at a time, so a second action cannot interleave with a delete halfway through;
/// the HUD reads this value, and Cancel is a cooperative flag checked between items.
@MainActor
@Observable
public final class BatchSession {
    public enum Kind: String, Sendable, Hashable {
        case trash
        case restore
        case deleteForever
        case favorite
        case rename
        case move
        case metadata
    }

    public struct Failure: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public var mediaID: MediaID
        public var name: String
        public var reason: String

        public init(mediaID: MediaID, name: String, reason: String) {
            self.mediaID = mediaID
            self.name = name
            self.reason = reason
        }
    }

    public let kind: Kind
    public private(set) var total: Int
    public private(set) var completed = 0
    public private(set) var failed = 0
    public private(set) var failures: [Failure] = []
    public private(set) var isCancelling = false
    public private(set) var currentName: String?

    public init(kind: Kind, total: Int) {
        self.kind = kind
        self.total = max(0, total)
    }

    public var fraction: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }

    public var isFinished: Bool { completed >= total }

    public var title: String {
        switch kind {
        case .trash: "Moving to Trash…"
        case .restore: "Restoring…"
        case .deleteForever: "Deleting…"
        case .favorite: "Updating favorites…"
        case .rename: "Renaming…"
        case .move: "Moving…"
        case .metadata: "Writing metadata…"
        }
    }

    public func begin(_ name: String) {
        currentName = name
    }

    public func record(_ item: MediaItem, error: String?) {
        completed += 1
        if let error {
            failed += 1
            failures.append(Failure(mediaID: item.id, name: item.name, reason: error))
        }
    }

    /// A cancelled batch still counts the completed prefix; the caller decides what to do with it.
    public func cancel() {
        isCancelling = true
    }

    /// Services that report progress as a count use this instead of ticking per item.
    public func advance(to done: Int) {
        completed = min(max(done, 0), total)
    }

    /// A service that reports failures at the end fills the list in one call.
    public func record(failures newFailures: [Failure]) {
        failures = newFailures
        failed = newFailures.count
        completed = total
    }
}
