import Foundation
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GallerySQLite
import GallerySupport

/// Pass B: read the files pass A only statued, and leave the grid something to draw.
///
/// This type is the consumer of `scan_queue` and nothing else. It does not enumerate, does not decide which
/// rows need work (pass A's `stage < thumbnailed` filter does that), and does not own the thumbnail cache —
/// a finished poster goes to `ThumbnailService`, so one code path knows how a cache file is named and counted.
/// That separation is what makes a relaunch mid-scan cheap: the queue is on disk, so the next process picks up
/// where this one stopped, and a crash costs one batch rather than a re-walk.
///
/// Two lanes, because the two file kinds are slow in different ways. An ImageIO decode is CPU-bound and wants
/// one permit per core; an `AVURLAsset` load is latency-bound and multiplies its own cost when a dozen of them
/// open at once. Neither may run on the cooperative pool the UI is scheduled on, which is why both go through
/// `BlockingLane`.
public actor MetadataWorker {
    public struct Configuration: Sendable {
        /// Rows per claim hop. Small enough that a viewport raise lands in the next hop, large enough that
        /// the queue's bookkeeping is one statement per hop instead of one per file.
        public var batchRows: Int
        /// The preview the grid draws. A bigger bucket costs decode time on every file in the library and
        /// buys nothing at a 320 px cell; the viewer's own sizes are baked on demand.
        public var posterBucket: ThumbnailBucket
        /// Attempts before a permanently unreadable file is parked: recorded, dropped from the queue, and
        /// left alone until the file itself changes.
        public var maximumAttempts: Int
        public var imageLane: BlockingLane
        public var videoLane: BlockingLane
        /// The zone a camera's wall-clock stamp is read against when its EXIF carries no offset.
        public var assumedZone: TimeZone

        public init(batchRows: Int = 64, posterBucket: ThumbnailBucket = .gridLarge,
                    maximumAttempts: Int = 3,
                    imageLane: BlockingLane = .imageBaking(),
                    videoLane: BlockingLane = BlockingLane(label: "app.gallery.avfoundation",
                                                           semaphore: .videoRead()),
                    assumedZone: TimeZone = .current) {
            self.batchRows = max(1, batchRows)
            self.posterBucket = posterBucket
            self.maximumAttempts = max(1, maximumAttempts)
            self.imageLane = imageLane
            self.videoLane = videoLane
            self.assumedZone = assumedZone
        }
    }

    /// What one `drain` did. Returned to the caller and logged; the HUD reads `progressFeed` instead.
    public struct Outcome: Sendable, Hashable {
        public var hops = 0
        public var claimed = 0
        /// Rows whose properties were read.
        public var metadataRead = 0
        /// Rows that also got a grid poster — the number pass B is really judged on.
        public var postersRecorded = 0
        /// Files that could not be read at all: damaged, unpermitted, or still in iCloud.
        public var failures = 0
        /// Files given up on after `maximumAttempts`, so the queue could drain past them.
        public var parked = 0
        /// Rows dropped because the catalog no longer has the file, or somebody else finished it.
        public var stale = 0
        /// Hops whose catalog write never landed. The rows stay queued, so this is a retry count, not a loss.
        public var droppedBatches = 0

        static func += (lhs: inout Outcome, rhs: Outcome) {
            lhs.hops += rhs.hops
            lhs.claimed += rhs.claimed
            lhs.metadataRead += rhs.metadataRead
            lhs.postersRecorded += rhs.postersRecorded
            lhs.failures += rhs.failures
            lhs.parked += rhs.parked
            lhs.stale += rhs.stale
            lhs.droppedBatches += rhs.droppedBatches
        }
    }

    private struct HopResult {
        var claimed = 0
        var metadata = 0
        var thumbnailed = 0
        var failed = 0
        var parked = 0
        var stale = 0
        var dropped = 0

        var outcome: Outcome {
            var result = Outcome()
            result.hops = 1
            result.claimed = claimed
            result.metadataRead = metadata
            result.postersRecorded = thumbnailed
            result.failures = failed
            result.parked = parked
            result.stale = stale
            result.droppedBatches = dropped
            return result
        }
    }

    private let catalog: Catalog
    private let reader: CatalogReader
    private let resolver: any MediaResolving
    private let thumbnails: ThumbnailService
    private let configuration: Configuration

    private var task: Task<Void, Never>?
    private var isDraining = false
    private var isPaused = false
    private var progress: [SourceID: IndexProgress] = [:]
    private var listeners: [UUID: AsyncStream<IndexProgress>.Continuation] = [:]

    public init(catalog: Catalog, reader: CatalogReader, resolver: any MediaResolving,
                thumbnails: ThumbnailService, configuration: Configuration = Configuration()) {
        self.catalog = catalog
        self.reader = reader
        self.resolver = resolver
        self.thumbnails = thumbnails
        self.configuration = configuration
    }

    // MARK: - Running

    /// Drains the queue and finishes. Tests await this directly; the UI uses `start` and watches the feed.
    /// Called while a drain is already running it does nothing: one queue, one consumer per process.
    public func drain() async -> Outcome {
        guard task == nil else { return Outcome() }
        return await drainGuarded()
    }

    public func start() {
        guard task == nil else { return }
        task = Task(priority: .utility) {
            let outcome = await self.drainGuarded()
            Log.indexing.info("pass B: \(outcome.metadataRead) read, \(outcome.postersRecorded) posters, \(outcome.failures) failed, \(outcome.parked) parked")
            self.task = nil
        }
    }

    /// The single-consumer gate. `start` and `drain` both funnel here, because two drains on one queue would
    /// each claim half a hop and charge every file for the doubled attempt.
    private func drainGuarded() async -> Outcome {
        guard !isDraining else { return Outcome() }
        isDraining = true
        let outcome = await drainLoop()
        isDraining = false
        return outcome
    }

    /// Stop pulling. The batch already in flight finishes and lands, because discarding decodes that are
    /// running costs the very previews the user is waiting for.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// Pausing stops the *next* claim. A hop is a few dozen files, so a pause takes effect within one batch
    /// rather than in the middle of it.
    public func setPaused(_ paused: Bool) async {
        isPaused = paused
        for sourceID in progress.keys { await publishSnapshot(sourceID) }
    }

    public var isRunning: Bool { task != nil }

    /// The rows on screen go to the front of the queue.
    ///
    /// Cheap and repeatable, which is what a scroll gesture needs: the statement only touches rows that are
    /// still queued, so a window dragged across a thousand finished photos writes nothing. Calling it while
    /// a hop is in flight is fine too — the raise lands for the *next* claim, which is the one after the
    /// batch the user has already been waiting for.
    public func raisePriority(mediaIDs: [MediaID]) async {
        guard !mediaIDs.isEmpty else { return }
        try? await catalog.raiseWorkPriority(mediaIDs: mediaIDs, priority: 1)
    }

    // MARK: - Progress

    /// Live progress, coalesced like pass A's: a worker that published per file would publish 100,000 times.
    public func progressFeed() -> AsyncStream<IndexProgress> {
        let (stream, continuation) = AsyncStream<IndexProgress>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let token = UUID()
        listeners[token] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeListener(token) }
        }
        return Coalescing(interval: .milliseconds(100)).attach(stream)
    }

    /// Where pass B has got to, read from the catalog rather than from this worker's memory: a HUD opened
    /// before the worker reached a folder, or a process relaunched mid-scan, has to show the whole library.
    /// An empty argument lists every source with rows in the queue.
    public func latestProgress(sourceID: SourceID? = nil) async -> [IndexProgress] {
        if let sourceID { return [await snapshot(sourceID)] }
        let known = Array(progress.keys)
        let pending = (try? await catalog.pendingSourceIDs()) ?? []
        let seen = Set(known)
        return await snapshotAll(known + pending.filter { !seen.contains($0) })
    }

    private func snapshotAll(_ sourceIDs: [SourceID]) async -> [IndexProgress] {
        var entries: [IndexProgress] = []
        for sourceID in sourceIDs { entries.append(await snapshot(sourceID)) }
        return entries
    }

    private func removeListener(_ token: UUID) { listeners[token] = nil }

    /// The catalog's own answer for a source: `stage` counts are the denominator, and they survive a
    /// relaunch, which is why progress is rebuilt from the database rather than remembered.
    private func snapshot(_ sourceID: SourceID) async -> IndexProgress {
        let stages = (try? await catalog.stageCounts(sourceID: sourceID)) ?? [:]
        let queued = (try? await catalog.queuedWorkCount(sourceID: sourceID)) ?? 0
        return IndexProgress(
            sourceID: sourceID,
            phase: queued == 0 ? .finished : .readingMetadata,
            discovered: stages.values.reduce(0, +),
            metadataDone: stages.filter { $0.key >= .metadata }.values.reduce(0, +),
            thumbnailed: stages[.thumbnailed] ?? 0,
            failed: (try? await catalog.problemCount(sourceID: sourceID)) ?? 0,
            queued: queued,
            isPaused: isPaused
        )
    }

    /// The hop's progress event. The numbers come from the catalog after its write, never from a tally added
    /// to whatever was remembered: a snapshot taken once the batch has landed already includes that batch, so
    /// the arithmetic would count every file twice on the hop that first touched its source.
    private func publishSnapshot(_ sourceID: SourceID) async {
        let fresh = await snapshot(sourceID)
        progress[sourceID] = fresh
        publish(fresh)
    }

    private func publish(_ progress: IndexProgress) {
        for listener in listeners.values { listener.yield(progress) }
    }

    // MARK: - The loop

    private func drainLoop() async -> Outcome {
        var outcome = Outcome()
        while !Task.isCancelled {
            await waitWhilePaused()
            guard let hop = await hop() else { break }
            outcome += hop.outcome
        }
        if !Task.isCancelled {
            for sourceID in progress.keys {
                // Re-read rather than declare: a scan may have queued more rows while the last claim was
                // coming back empty, and `finished` is a claim about the whole folder.
                await publishSnapshot(sourceID)
            }
        }
        return outcome
    }

    private func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One claim hop, end to end: take rows, read them in parallel, write them in one transaction, then
    /// settle the queue. Nil means the queue is empty, which is what ends a drain.
    private func hop() async -> HopResult? {
        let claimed = (try? await catalog.claimWork(limit: configuration.batchRows)) ?? []
        guard !claimed.isEmpty else { return nil }
        var result = HopResult(claimed: claimed.count)

        let ids = claimed.compactMap(\.mediaID)
        var found: [MediaID: MediaItem] = [:]
        for item in ids.isEmpty ? [] : ((try? await reader.items(ids: ids)) ?? []) { found[item.id] = item }
        let rows = found
        let targets = await resolver.targets(for: ids)
        let thumbnails = self.thumbnails
        let configuration = self.configuration

        let verdicts = await withTaskGroup(of: Work?.self) { group in
            for job in claimed {
                group.addTask {
                    await MetadataWorker.settle(job, rows: rows, targets: targets,
                                                thumbnails: thumbnails, configuration: configuration)
                }
            }
            var settled: [Work] = []
            settled.reserveCapacity(claimed.count)
            for await work in group {
                if let work { settled.append(work) }
            }
            return settled
        }

        var writes: [MediaItem] = []
        var retired: [Int64] = []
        var noted: [(queueID: Int64, message: String)] = []
        var sources: Set<SourceID> = []
        for work in verdicts {
            sources.insert(work.sourceID)
            switch work.verdict {
            case .stale:
                retired.append(work.queueID)
                result.stale += 1
            case .settled(let item, let posterWritten):
                writes.append(item)
                retired.append(work.queueID)
                fold(item, into: &result)
                if posterWritten { result.thumbnailed += 1 }
            case .failed(let item, let error, let parked):
                writes.append(item)
                noted.append((work.queueID, error.userReason))
                fold(item, into: &result)
                result.failed += 1
                if parked {
                    retired.append(work.queueID)
                    result.parked += 1
                }
            }
        }

        guard await write(writes) else {
            // The rows are claimed and their `attempts` are bumped, so an unwritten batch is one that will be
            // claimed again. Nothing here needs rolling back — and nothing here may be settled.
            result.dropped = 1
            Log.indexing.error("pass B dropped a \(writes.count)-row batch")
            return result
        }

        try? await catalog.completeWork(ids: retired)
        for note in noted {
            try? await catalog.failWork(id: note.queueID, error: note.message)
        }
        for sourceID in sources {
            await publishSnapshot(sourceID)
        }
        return result
    }

    /// What a written row adds to this hop's counters. `stage` is the only record of how far pass B got, so
    /// the numbers the HUD adds up are the numbers the catalog holds.
    private func fold(_ item: MediaItem, into result: inout HopResult) {
        if item.stage >= .metadata { result.metadata += 1 }
        // A stub in iCloud is a file this pass could not read, and the Problems view counts it; a photo whose
        // poster failed is not, because its date, GPS and pixel size all landed.
        if item.error == .offline { result.failed += 1 }
    }

    /// The one catalog write per hop, on the same lock ladder pass A uses: a second Gallery process holding
    /// the write lock is a reason to wait, and a batch that never landed stays queued instead of being lost.
    private func write(_ rows: [MediaItem]) async -> Bool {
        guard !rows.isEmpty else { return true }
        var burned = 0
        while true {
            do {
                try await catalog.recordMetadata(rows)
                return true
            } catch let error as SQLiteError where error.isLockContention {
                guard burned < LockBackoff.maximumAttempts else { return false }
                burned += 1
                try? await Task.sleep(for: LockBackoff.delay(afterAttempt: burned - 1) + LockBackoff.jitter())
            } catch {
                Log.indexing.error("pass B metadata write failed: \(error, privacy: .public)")
                return false
            }
        }
    }

    // MARK: - One file

    /// The verdict for one claimed row. Every case here is a decision about the *queue*, which is why
    /// "already finished" and "cannot be read" are different outcomes: one is done, the other gets a birthday.
    ///
    /// Static rather than actor-isolated: a hop runs its files concurrently, and the only reason a child task
    /// may touch this worker's dependencies is that they are all themselves actors. Keeping the per-file path
    /// off the actor also means one slow ImageIO decode cannot stall the worker's progress bookkeeping.
    private static func settle(_ job: WorkItem, rows: [MediaID: MediaItem],
                               targets: [MediaID: MediaTarget], thumbnails: ThumbnailService,
                               configuration: Configuration) async -> Work? {
        guard let mediaID = job.mediaID, let row = rows[mediaID] else {
            return Work(job, .stale)
        }
        // Another process — a relaunch, a second window — finished this file while the batch was in flight.
        // Writing our own copy would be a regression, and the queue entry is worthless.
        guard row.stage < .thumbnailed else { return Work(job, .stale) }

        // A file that is only a stub in iCloud is not a decode failure, and downloading it silently is not
        // this worker's decision to make. The row gets the badge; the queue is done with it until a scan sees
        // real bytes, because `enqueuePendingWork` re-queues whatever the next walk finds still unfinished.
        if row.isOffline {
            return Work(job, .settled(MetadataRules.unreadable(row, .offline)))
        }
        guard let target = targets[mediaID] else {
            return failure(job, row, .noAccess, attempts: job.attempts, maximumAttempts: configuration.maximumAttempts)
        }
        guard let still = await read(row, target, configuration: configuration) else { return nil }

        switch still {
        case .failed(let error):
            return failure(job, row, error, attempts: job.attempts, maximumAttempts: configuration.maximumAttempts)
        case .decoded(let metadata, let poster):
            var item = MetadataRules.refine(row, from: metadata, zone: configuration.assumedZone)
            item.stage = .metadata
            item.error = .none
            var posterWritten = false
            if let poster {
                // The row says what the cache can actually serve. A poster that could not be written is a
                // photo with a real date and no preview, which is a badge — not a pass B that claimed done.
                posterWritten = await thumbnails.recordBaked(
                    poster, ThumbnailService.Request(item: item), bucket: configuration.posterBucket
                )
                if posterWritten {
                    item.stage = .thumbnailed
                } else {
                    item.error = .noThumbnail
                }
            } else {
                item.error = .noThumbnail
            }
            return Work(job, .settled(item, posterWritten: posterWritten))
        }
    }

    /// One file's failure: record the badge, and let the attempt count decide whether the queue keeps it.
    private static func failure(_ job: WorkItem, _ row: MediaItem, _ error: IndexError,
                                attempts: Int, maximumAttempts: Int) -> Work {
        let item = MetadataRules.unreadable(row, error)
        return Work(job, .failed(row: item, error: error, parked: attempts >= maximumAttempts))
    }

    /// The blocking half, on its lane, with the folder's grant begun for the duration. `SecurityScope` is
    /// per-folder, so the root the resolver found is the thing access opens on, not the file inside it.
    /// Nil means the task was cancelled before the lane took the work.
    private static func read(_ row: MediaItem, _ target: MediaTarget,
                             configuration: Configuration) async -> StillDecodeOutcome? {
        let url = target.url
        let root = target.scopedRoot ?? url
        let bucket = configuration.posterBucket
        switch row.kind {
        case .video:
            guard let outcome = await configuration.videoLane.bounded({
                (try? await SecurityScope.withAccess(to: root) {
                    await MetadataWorker.readVideo(at: url, bucket: bucket)
                }) ?? .failed(.noAccess)
            }) else { return nil }
            return outcome
        default:
            guard case .completed(let outcome) = await configuration.imageLane.run({
                SecurityScope.withAccess(to: root) { ImageMetadataReader.decode(url, posterIn: bucket) }
            }) else { return nil }
            return outcome
        }
    }

    /// A clip's properties and its poster, from one asset. The still-image reader is not tried for a video
    /// because a clip's first frame is not in its header, and `AVAssetImageGenerator` is the only API that
    /// downsamples while decoding.
    private static func readVideo(at url: URL, bucket: ThumbnailBucket) async -> StillDecodeOutcome {
        switch await VideoMetadataReader.read(at: url) {
        case .failed(let error): .failed(error)
        case .decoded(let metadata):
            .decoded(metadata: metadata, poster: await ThumbnailBaker.videoPoster(url: url, bucket: bucket))
        }
    }
}

/// What one file came to. `stale` and `settled` both leave the queue; only a non-parked `failed` stays in it.
private struct Work: Sendable {
    enum Verdict: Sendable {
        /// Nothing to write: the file left the catalog, or another process finished it.
        case stale
        /// Read, and stored with whatever stage the poster earned.
        case settled(MediaItem, posterWritten: Bool = false)
        /// Not readable this attempt — recorded, and kept in the queue unless `parked` says the last allowed
        /// try is behind us. One damaged file must not hold a library's queue open forever.
        case failed(row: MediaItem, error: IndexError, parked: Bool)
    }

    var queueID: Int64
    var sourceID: SourceID
    var verdict: Verdict

    init(_ job: WorkItem, _ verdict: Verdict) {
        self.queueID = job.queueID
        self.sourceID = job.sourceID
        self.verdict = verdict
    }
}
