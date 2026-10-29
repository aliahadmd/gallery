import Foundation
import CoreGraphics
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GallerySupport

/// The pixel side channel: memory, then disk, then a decode of the original.
///
/// The three tiers have wildly different costs — a memory hit is a pointer read, a disk hit is a small JPEG
/// decode, a miss is a downsampled decode of a multi-megabyte file plus a file write and a catalog row — so
/// the entire job of this type is making each request pay the cheapest tier that can answer it. Two
/// properties matter more than the rest, and everything else is in service of them: a hundred cells scrolling
/// into view bake *one* thumbnail each, and no blocking ImageIO decode ever runs on the cooperative pool the
/// UI is using.
///
/// The catalog manifest is touched only on the cold tiers. A memory hit deliberately does no database work at
/// all, which is what keeps a flicked-through 100k library from spending its scroll budget on SQLite.
public actor ThumbnailService {
    /// One picture at one invalidation stamp — which is the whole cache key, so a request carries the stamp
    /// the caller's row has rather than asking the catalog for it again.
    public struct Request: Sendable, Hashable {
        public var mediaID: MediaID
        /// The source file's modification date, or nil for a file that reports none. The disk name and the
        /// manifest row are both built from it, so an edited-outside-the-app photo is a miss by construction.
        public var mtime: Date?

        public init(mediaID: MediaID, mtime: Date?) {
            self.mediaID = mediaID
            self.mtime = mtime
        }

        public init(item: MediaItem) {
            self.init(mediaID: item.id, mtime: item.modificationDate)
        }
    }

    public struct Configuration: Sendable {
        /// Half a gigabyte, or a sixth of RAM — the grid at 320 px is ~400 KB a picture decoded, so 512 MB is
        /// roughly 1,300 cells, far more than any window. NSCache treats this as a ceiling it may come in
        /// under, which is the right shape for a process that should never be the one the kernel kills.
        public var memoryCostLimit: Int
        /// Prefetch gets its own small bound rather than the decode lane's full width: a fast scroll asking
        /// for eight screens ahead is eight screens of bitmaps nobody draws, and the lane is the interactive
        /// cells' too.
        public var prefetchWorkers: Int
        /// Display ticks are batched because a grid that writes one transaction per displayed cell is doing
        /// more SQLite work than the scan it is racing.
        public var touchBatchRows: Int
        public var evictionChunkRows: Int

        public init(memoryCostLimit: Int = ThumbnailService.defaultMemoryCostLimit,
                    prefetchWorkers: Int = 2, touchBatchRows: Int = 200, evictionChunkRows: Int = 200) {
            self.memoryCostLimit = max(1, memoryCostLimit)
            self.prefetchWorkers = max(0, prefetchWorkers)
            self.touchBatchRows = max(1, touchBatchRows)
            self.evictionChunkRows = max(1, evictionChunkRows)
        }
    }

    /// Counted rather than logged, because "is the cache working" is a question with a number in the answer
    /// and every tier boundary is a test.
    public struct Statistics: Sendable, Hashable {
        public var memoryHits = 0
        public var diskHits = 0
        /// Full decodes of an original — the only tier that costs real time.
        public var bakes = 0
        /// Requests no tier could answer: a vanished file, an undecodable one, or a row this process cannot
        /// reach. Baked failures are not cached, so the next request tries again.
        public var failures = 0
        /// Window entries discarded before a worker reached them, which is the cost side of a fast scroll.
        public var prefetchDropped = 0
    }

    public static let defaultMemoryCostLimit: Int = {
        let sixth = Int(ProcessInfo.processInfo.physicalMemory / 6)
        return min(512 * 1024 * 1024, max(64 * 1024 * 1024, sixth))
    }()

    private let catalog: Catalog
    private let store: ThumbnailStore
    private let resolver: any MediaResolving
    private let configuration: Configuration
    private let lane: BlockingLane
    private let memory: MemoryTier
    private let coalescer = BakeCoalescer()

    private var statistics = Statistics()
    private var pendingTouches: [BakeKey: Date] = [:]
    /// The window still to be prefetched, in the order the view drew it.
    private var pending: [(request: Request, bucket: ThumbnailBucket)] = []
    private var window: [Request] = []
    private var windowBucket: ThumbnailBucket?
    private var prefetchWorkers: [Task<Void, Never>] = []

    public init(catalog: Catalog, store: ThumbnailStore, resolver: any MediaResolving,
                configuration: Configuration = Configuration(), lane: BlockingLane = .imageBaking()) {
        self.catalog = catalog
        self.store = store
        self.resolver = resolver
        self.configuration = configuration
        self.lane = lane
        self.memory = MemoryTier(costLimit: configuration.memoryCostLimit)
    }

    public var stats: Statistics { statistics }

    // MARK: - Requests

    /// The picture for this cell, from the cheapest tier that has it.
    ///
    /// Returns nil when the file cannot be drawn — a placeholder badge is the caller's job, and this type has
    /// no opinion about what a cell should look like.
    public func image(_ request: Request, bucket: ThumbnailBucket) async -> CGImage? {
        let key = BakeKey(request, bucket)
        if let cached = memory.image(for: key) {
            statistics.memoryHits += 1
            return cached
        }
        let coalescer = self.coalescer
        switch coalescer.join(key) {
        case .image(let outcome):
            return outcome
        case .wait(let id, let mustProduce):
            if mustProduce {
                Task { await self.produce(key: key, request: request, bucket: bucket) }
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    switch coalescer.register(key, id, continuation) {
                    case .parked: break
                    case .outcome(let outcome): continuation.resume(returning: outcome)
                    }
                }
            } onCancel: {
                coalescer.cancel(key, id)
            }
        }
    }

    /// Record a thumbnail somebody else baked — pass B decodes the file for its own reasons and should hand
    /// the bytes here rather than reimplementing the naming, the write and the manifest row that a display hit
    /// has to agree with.
    ///
    /// False when the file could not be written, which is the caller's answer to "may I call this row
    /// thumbnailed". A row that claims a preview the cache does not have is the one lie a grid cannot
    /// recover from: it draws a placeholder forever.
    @discardableResult
    public func recordBaked(_ jpeg: Data, _ request: Request, bucket: ThumbnailBucket) async -> Bool {
        let store = self.store
        guard case .completed(let path) = await lane.run({
            (try? store.save(jpeg, mediaID: request.mediaID, bucket: bucket,
                             mtime: request.mtime))?.path
        }), let path else { return false }
        try? await catalog.noteThumbnail(ThumbnailRecord(
            mediaID: request.mediaID, bucket: bucket, mtime: request.mtime, path: path,
            byteSize: Int64(jpeg.count), lastUsed: Date()
        ))
        return true
    }

    // MARK: - The window

    /// What the user can see, in draw order, ± the pages the view is willing to decode ahead.
    ///
    /// Calling this replaces the prefetch queue, so everything outside the new window is dropped *before* it
    /// costs a decode — that is the whole defence against a flicked scroll filling the lane with bitmaps
    /// nobody drew. Work already handed to the decode lane finishes and lands in the cache, because a
    /// thumbnail that is baked is worth keeping and cancelling a shared bake would penalise the cell that is
    /// actually on screen.
    public func setWindow(_ requests: [Request], bucket: ThumbnailBucket) {
        guard requests != window || bucket != windowBucket else { return }
        let staying = Set(requests.map(\.mediaID))
        statistics.prefetchDropped += pending.filter { !staying.contains($0.request.mediaID) }.count
        window = requests
        windowBucket = bucket
        pending = requests.map { ($0, bucket) }
        restartWorkers()
    }

    /// The visible window is gone — grid off-screen, viewer dismissed, slideshow paused. Stop queueing work
    /// for it; requests already handed to the decode lane finish into the cache.
    public func clearWindow() {
        guard !window.isEmpty else { return }
        statistics.prefetchDropped += pending.count
        window = []
        windowBucket = nil
        pending = []
        restartWorkers()
    }

    /// Replacing the window means new workers: a cancelled one stops pulling, and the work it was mid-await on
    /// keeps going on its own, because cancelling the *waiter* is not cancelling the *bake*.
    private func restartWorkers() {
        for worker in prefetchWorkers { worker.cancel() }
        prefetchWorkers = (0..<configuration.prefetchWorkers).map { _ in
            Task(priority: .utility) { await self.drainWindow() }
        }
    }

    private func drainWindow() async {
        while !Task.isCancelled {
            guard !pending.isEmpty else { return }
            let next = pending.removeFirst()
            _ = await image(next.request, bucket: next.bucket)
        }
    }

    // MARK: - Maintenance

    /// Forget every bitmap, keeping the disk cache. The viewer's dismiss and the app's memory-pressure notice
    /// both land here; the trigger stays with the caller so this type never subscribes to AppKit.
    public func purgeMemory() { memory.removeAll() }

    /// Write the buffered LRU ticks.
    ///
    /// Public because quitting is exactly the moment the bookkeeping matters: a window's worth of displays
    /// that never reached the manifest is a cache that evicts the pictures the user was looking at.
    public func flushTouches() async {
        guard !pendingTouches.isEmpty else { return }
        let touches = pendingTouches
        pendingTouches = [:]
        let store = self.store
        for (key, usedAt) in touches {
            let request = key.request
            try? await catalog.touchThumbnail(mediaID: request.mediaID, bucket: key.bucket,
                                              mtime: request.mtime,
                                              path: store.layout.url(mediaID: request.mediaID, bucket: key.bucket,
                                                                    mtime: request.mtime).path,
                                              usedAt: usedAt)
        }
    }

    /// Trim the disk cache to its budget, coldest manifest row first, and report the bytes actually deleted.
    ///
    /// The manifest is the authority because it is the only thing that knows which files were *drawn*; a
    /// thumbnail's own dates say when it was baked, which is not the same fact. Orphans are expected, not a
    /// bug to fix here: deleting a media row leaves its thumbnails behind on purpose, and this is what
    /// eventually reclaims them. `ThumbnailStore`'s tree sweep stays the fallback for files no row describes.
    @discardableResult
    public func enforceBudget() async -> Int64 {
        await flushTouches()
        let limit = store.byteLimit
        guard var used = try? await catalog.thumbnailManifestBytes(), used > limit else { return 0 }
        var freed: Int64 = 0
        while used > limit, !Task.isCancelled {
            let coldest = (try? await catalog.coldestThumbnails(limit: configuration.evictionChunkRows)) ?? []
            if coldest.isEmpty { break }
            let paths = coldest.map(\.path)
            var removed: Int64 = 0
            if case .completed(let bytes) = await lane.run({
                var freed: Int64 = 0
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
                    freed += size
                }
                return freed
            }) {
                removed = bytes
            }
            // Rows go whether or not the file was there — a row whose picture was already deleted out from
            // under us is the definition of a candidate, and leaving it would make this loop pick it forever.
            try? await catalog.deleteThumbnailRows(paths: paths)
            // The budget is kept in the manifest's own numbers, so the estimate and the database can only
            // disagree in the direction of pruning a little more than asked.
            used -= coldest.reduce(0) { $0 + $1.byteSize }
            freed += removed
        }
        return freed
    }

    // MARK: - Tiers

    /// One cold request, end to end. Runs in its own task, which is what lets a hundred cells for the same
    /// picture share it.
    private func produce(key: BakeKey, request: Request, bucket: ThumbnailBucket) async {
        var image = await loadFromDisk(request, bucket: bucket, key: key)
        if image == nil { image = await bake(request, bucket: bucket) }
        if let image { memory.insert(image, for: key) } else { statistics.failures += 1 }
        coalescer.deliver(key, image)
    }

    /// Tier 2: the JPEG that is already on disk.
    private func loadFromDisk(_ request: Request, bucket: ThumbnailBucket, key: BakeKey) async -> CGImage? {
        let store = self.store
        guard case .completed(let image) = await lane.run({ () -> CGImage? in
            guard let data = store.load(mediaID: request.mediaID, bucket: bucket, mtime: request.mtime) else {
                return nil
            }
            return ThumbnailBaker.image(from: data)
        }), let image else { return nil }
        statistics.diskHits += 1
        pendingTouches[key] = Date()
        if pendingTouches.count >= configuration.touchBatchRows {
            Task { await self.flushTouches() }
        }
        return image
    }

    /// Tier 3: ask where the file is, then decode it down to the bucket. A cache file that could not be read
    /// lands here too, and the write below replaces it — so a JPEG torn by a crash self-heals on the next
    /// request instead of needing a sweep to notice.
    private func bake(_ request: Request, bucket: ThumbnailBucket) async -> CGImage? {
        guard let target = await resolver.targets(for: [request.mediaID])[request.mediaID] else { return nil }
        let scopedRoot = target.scopedRoot ?? target.url
        let store = self.store
        guard case .completed(let result) = await lane.run({
            let jpeg = SecurityScope.withAccess(to: scopedRoot) {
                ThumbnailBaker.bake(url: target.url, bucket: bucket)
            }
            guard let jpeg else { return Baked(image: nil, path: nil, byteSize: 0) }
            let path = try? store.save(jpeg, mediaID: request.mediaID, bucket: bucket,
                                       mtime: request.mtime).path
            // Decoding the bytes we just wrote, rather than handing back the bitmap the encoder was given: a
            // bake and a later disk hit must return the same pixels, or purging the memory tier would visibly
            // change the picture. One small JPEG decode is a millisecond.
            return Baked(image: ThumbnailBaker.image(from: jpeg), path: path, byteSize: Int64(jpeg.count))
        }), let image = result.image else { return nil }
        statistics.bakes += 1
        if let path = result.path {
            try? await catalog.noteThumbnail(ThumbnailRecord(
                mediaID: request.mediaID, bucket: bucket, mtime: request.mtime, path: path,
                byteSize: result.byteSize, lastUsed: Date()
            ))
        }
        return image
    }
}

/// Which bake a request is waiting for: the picture, the bucket, and the stamp that invalidates it.
private struct BakeKey: Hashable, Sendable {
    var mediaID: MediaID
    var bucket: ThumbnailBucket
    var stamp: Int64

    init(_ request: ThumbnailService.Request, _ bucket: ThumbnailBucket) {
        self.mediaID = request.mediaID
        self.bucket = bucket
        self.stamp = request.mtime?.nanoseconds ?? 0
    }

    var request: ThumbnailService.Request {
        ThumbnailService.Request(mediaID: mediaID, mtime: stamp == 0 ? nil : Date(nanoseconds: stamp))
    }

    /// The memory tier's key — the same three facts the disk name is built from, spelled as a string because
    /// that is what `NSCache` wants and what makes a stale stamp unreachable rather than invalidated.
    var name: String { "\(mediaID.rawValue)/\(bucket.longSide)/\(stamp)" }
}

/// A cold bake's output: the pixels to draw, and the file and size to record.
private struct Baked: Sendable {
    var image: CGImage?
    var path: String?
    var byteSize: Int64
}

/// The hot tier: bitmaps this process is prepared to draw on the next frame.
///
/// `NSCache` rather than a dictionary because it reacts to memory pressure by itself and evicts off the main
/// thread; the cost is the *decoded* bitmap's bytes, not the JPEG's, which is the only number that correlates
/// with what the app is actually holding. The limit is advisory by design — a gallery that kept 512 MB of grid
/// bitmaps while another app was swapping would be the one the kernel chose, with worse manners.
private final class MemoryTier: @unchecked Sendable {
    final class Box: NSObject {
        let image: CGImage
        let cost: Int

        init(_ image: CGImage) {
            self.image = image
            self.cost = image.bytesPerRow * image.height
        }
    }

    private let cache = NSCache<NSString, Box>()

    init(costLimit: Int) {
        cache.totalCostLimit = costLimit
    }

    func image(for key: BakeKey) -> CGImage? {
        cache.object(forKey: key.name as NSString)?.image
    }

    func insert(_ image: CGImage, for key: BakeKey) {
        let box = Box(image)
        cache.setObject(box, forKey: key.name as NSString, cost: box.cost)
    }

    func removeAll() { cache.removeAllObjects() }
}

/// Who is waiting for one bake, and how to hand them the picture.
///
/// A lock-guarded class rather than actor state for the same reason as `AsyncSemaphore`: the continuation only
/// exists inside `withCheckedContinuation`'s synchronous closure, and a hop back into the actor from there is
/// not something the language allows. It also buys the property a `Task` handle cannot: cancelling one waiter
/// — a cell that scrolled away — does not cancel the bake the other ninety-nine are waiting on, because
/// nobody holds a cancellable handle to it.
private final class BakeCoalescer: @unchecked Sendable {
    enum Join {
        /// Already answered since the caller probed the memory tier.
        case image(CGImage?)
        /// Wait for it; `mustProduce` marks the request that has to start the decode.
        case wait(id: UInt64, mustProduce: Bool)
    }

    enum Registration {
        case parked
        case outcome(CGImage?)
    }

    private struct Waiter {
        var id: UInt64
        var continuation: CheckedContinuation<CGImage?, Never>?
        var isCancelled = false
    }

    private struct Entry {
        var waiters: [Waiter] = []
        var isRunning = true
        var outcome: CGImage?
    }

    private let lock = NSLock()
    private var entries: [BakeKey: Entry] = [:]
    private var nextWaiterID: UInt64 = 0

    func join(_ key: BakeKey) -> Join {
        lock.withLock {
            let id = nextWaiterID
            nextWaiterID += 1
            guard var entry = entries[key] else {
                entries[key] = Entry(waiters: [Waiter(id: id)])
                return .wait(id: id, mustProduce: true)
            }
            guard entry.isRunning else {
                // The bake answered between the caller's memory probe and this join, so it takes the outcome
                // straight back and never registers a continuation.
                let outcome = entry.outcome
                prune(&entry, key: key)
                return .image(outcome)
            }
            entry.waiters.append(Waiter(id: id))
            entries[key] = entry
            return .wait(id: id, mustProduce: false)
        }
    }

    func register(_ key: BakeKey, _ id: UInt64,
                  _ continuation: CheckedContinuation<CGImage?, Never>) -> Registration {
        lock.withLock {
            guard var entry = entries[key], let position = entry.waiters.firstIndex(where: { $0.id == id })
            else { return .outcome(nil) }
            let waiter = entry.waiters[position]
            guard waiter.continuation == nil else {
                // Registered twice for one reservation, which the caller's contract makes impossible; hand
                // back the answer rather than stacking continuations that would double-resume.
                return waiter.isCancelled ? .outcome(nil) : .outcome(entry.isRunning ? nil : entry.outcome)
            }
            if waiter.isCancelled {
                entry.waiters.remove(at: position)
                prune(&entry, key: key)
                return .outcome(nil)
            }
            if !entry.isRunning {
                let outcome = entry.outcome
                entry.waiters.remove(at: position)
                prune(&entry, key: key)
                return .outcome(outcome)
            }
            entry.waiters[position].continuation = continuation
            entries[key] = entry
            return .parked
        }
    }

    func deliver(_ key: BakeKey, _ outcome: CGImage?) {
        let resumed: [CheckedContinuation<CGImage?, Never>] = lock.withLock {
            guard var entry = entries[key], entry.isRunning else { return [] }
            entry.isRunning = false
            entry.outcome = outcome
            var done: [CheckedContinuation<CGImage?, Never>] = []
            entry.waiters = entry.waiters.compactMap { waiter in
                guard let continuation = waiter.continuation, !waiter.isCancelled else { return waiter }
                done.append(continuation)
                return nil
            }
            prune(&entry, key: key)
            return done
        }
        // Outside the lock, as always: a resumed task must not run its first instructions while this class is
        // still holding it.
        for continuation in resumed { continuation.resume(returning: outcome) }
    }

    func cancel(_ key: BakeKey, _ id: UInt64) {
        let continuation: CheckedContinuation<CGImage?, Never>? = lock.withLock {
            guard var entry = entries[key], let position = entry.waiters.firstIndex(where: { $0.id == id })
            else { return nil }
            let waiter = entry.waiters[position]
            if waiter.continuation == nil {
                // Cancelled in the window between reserving a place and registering the continuation. The
                // reservation stays, flagged, so `register` can answer it instead of parking it forever.
                entry.waiters[position].isCancelled = true
                entries[key] = entry
                return nil
            }
            entry.waiters.remove(at: position)
            prune(&entry, key: key)
            return waiter.continuation
        }
        continuation?.resume(returning: nil)
    }

    /// Call with the lock held.
    ///
    /// A bake that is still running keeps its entry even with nobody left to tell, because the next ask for
    /// the same picture must coalesce onto the decode that is already happening rather than start a second
    /// one — and scrolling away and back is exactly how that ask arrives. An *answered* entry with no waiters
    /// is dead weight: the memory tier is where that outcome lives now, and a long-lived cache would
    /// otherwise accumulate one dead record per picture ever scrolled past.
    private func prune(_ entry: inout Entry, key: BakeKey) {
        if entry.waiters.isEmpty, !entry.isRunning {
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }
}
