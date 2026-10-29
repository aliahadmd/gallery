import AVFoundation
import Foundation
import GalleryDomain
import GalleryIndexing
import GallerySupport

/// The clips that are open right now.
///
/// Two, not one: the clip on screen and the one the user is about to step to. More than that is a decoder
/// per press of the arrow key — `AVPlayer` is cheap to make and expensive to keep, because a paused player
/// still holds its decode pipeline and audio session.
///
/// Eviction is the part that matters for the grid: `pause()` and `replaceCurrentItem(nil)`. Dropping the
/// last reference to a player is not the same event as stopping it — an `AVPlayer` tearing down on someone
/// else's schedule is an audio track that keeps playing over the next photo.
@MainActor
public final class PlayerPool {
    /// One resolved clip, ready to attach to a layer.
    public struct Lease {
        public let player: AVPlayer
        public let item: MediaItem
        public let target: MediaTarget
    }

    private struct Entry {
        let lease: Lease
        var lastUsed: UInt64
    }

    private let resolver: any MediaResolving
    private let capacity: Int
    private let makePlayer: @MainActor (URL) -> AVPlayer
    private var entries: [MediaID: Entry] = [:]
    private var clock: UInt64 = 0

    /// The factory is injectable so the pool's accounting can be tested without a video file or a display;
    /// the app always passes the default, which is `AVPlayer(url:)`.
    public init(resolver: any MediaResolving,
                capacity: Int = PlayerPool.defaultCapacity,
                makePlayer: @escaping @MainActor (URL) -> AVPlayer = { AVPlayer(url: $0) }) {
        self.resolver = resolver
        self.capacity = max(1, capacity)
        self.makePlayer = makePlayer
    }

    public static let defaultCapacity = 2

    public var openCount: Int { entries.count }

    public func isOpen(_ id: MediaID) -> Bool { entries[id] != nil }

    /// The player for this item, made on first ask and reused while it is inside the window.
    ///
    /// Nil means the catalog cannot place the file, which is the same answer the cells get; the viewer shows
    /// a reason rather than a spinner that never ends.
    public func player(for item: MediaItem) async -> Lease? {
        clock += 1
        if var entry = entries[item.id] {
            entry.lastUsed = clock
            entries[item.id] = entry
            return entry.lease
        }
        guard let target = await resolver.targets(for: [item.id])[item.id] else { return nil }

        // Playback outlives any single call, so the scope is held by the entry rather than a closure.
        SecurityScope.begin(target.scopedRoot ?? target.url)
        let player = makePlayer(target.url)
        // A local file needs no stalling allowance; an external or network volume does, or the first second
        // of every clip is a stutter while the reader catches up.
        player.automaticallyWaitsToMinimizeStalling = VolumeIdentity.isRemovable(target.url)

        let lease = Lease(player: player, item: item, target: target)
        entries[item.id] = Entry(lease: lease, lastUsed: clock)
        trim()
        return lease
    }

    /// Stops everything except the clip being shown. Called on every step through the viewer, so a photo
    /// after a clip is a photo in silence.
    public func evict(except keeping: MediaID?) {
        for (id, entry) in entries where id != keeping {
            entries[id] = nil
            discard(entry.lease)
        }
    }

    /// Stops and forgets every clip. The window closing or the viewer dismissing is the end of playback,
    /// not a pause the user has to find.
    public func stopAll() {
        for entry in entries.values { discard(entry.lease) }
        entries.removeAll()
    }

    private func trim() {
        while entries.count > capacity {
            guard let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
            entries[oldest.key] = nil
            discard(oldest.value.lease)
        }
    }

    private func discard(_ lease: Lease) {
        lease.player.pause()
        lease.player.replaceCurrentItem(with: nil)
        SecurityScope.end(lease.target.scopedRoot ?? lease.target.url)
    }
}
