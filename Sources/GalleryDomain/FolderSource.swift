import Foundation

/// Whether we can still reach the folder the user picked. Persisted as a raw code so the sidebar badge
/// survives a relaunch without re-resolving every bookmark.
public enum BookmarkState: Int16, Sendable, Hashable, Codable, CaseIterable {
    case ok = 0
    case needsUserPick = 1
    case volumeMissing = 2
    case accessDenied = 3

    public var userReason: String {
        switch self {
        case .ok: ""
        case .needsUserPick: "Gallery lost the permission to this folder. Pick it again."
        case .volumeMissing: "The drive this folder lives on isn't connected."
        case .accessDenied: "Access was revoked in System Settings → Privacy & Security."
        }
    }

    /// Anything but `.ok` means the grid must read from the catalog only — no filesystem calls, no retry loop.
    public var blocksScanning: Bool { self != .ok }
}

/// Live state of the folder watcher, which is a different question from whether we can *read* the folder.
public enum WatcherState: Sendable, Hashable, Codable {
    case idle
    case watching
    case mustRescan(reason: String)
    case unsupported(reason: String)

    /// The persisted half of the state. A rescan reason is a toast, not a record — the sidebar badge only
    /// needs to know which of these four things is true, and the column is an INTEGER so a reason would
    /// have to live somewhere it can't be.
    public var code: Int16 {
        switch self {
        case .idle: 0
        case .watching: 1
        case .mustRescan: 2
        case .unsupported: 3
        }
    }

    public init(code: Int16) {
        switch code {
        case 1: self = .watching
        case 2: self = .mustRescan(reason: "File events were missed while Gallery was closed.")
        case 3: self = .unsupported(reason: "This volume doesn't deliver file events; using timed sweeps.")
        default: self = .idle
        }
    }
}

public struct FolderSource: Identifiable, Sendable, Hashable, Codable {
    public let id: SourceID

    public var displayName: String

    /// Stored root-relative-to-volume plus the volume identifier, so a remount at `/Volumes/SD 1` instead
    /// of `/Volumes/SD` rebinds the rows instead of looking like 40,000 deleted photos.
    public var rootPath: String
    public var volumeID: String

    public var bookmarkState: BookmarkState
    public var watcherState: WatcherState

    /// FSEvents catch-up token. Held per source so a restart resumes from the last observed event rather
    /// than a full rescan.
    public var lastEventID: UInt64?
    public var lastSweep: Date?
    public var lastScan: Date?
    public var isIncluded: Bool

    public init(
        id: SourceID,
        displayName: String,
        rootPath: String,
        volumeID: String,
        bookmarkState: BookmarkState = .ok,
        watcherState: WatcherState = .idle,
        lastEventID: UInt64? = nil,
        lastSweep: Date? = nil,
        lastScan: Date? = nil,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.volumeID = volumeID
        self.bookmarkState = bookmarkState
        self.watcherState = watcherState
        self.lastEventID = lastEventID
        self.lastSweep = lastSweep
        self.lastScan = lastScan
        self.isIncluded = isIncluded
    }

    public var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
}
