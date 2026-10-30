import Foundation
import GalleryDomain
import GalleryCatalog
import GallerySQLite
import GallerySupport

/// Why a folder could not be indexed at all — as distinct from one bad file, which is a row carrying an
/// `IndexError` instead of an error here.
public enum IndexingError: Error, Sendable, Hashable, CustomStringConvertible {
    case recycledFolder(path: String)
    case volumeUnavailable(path: String)
    /// The folder resolves but the system refuses to list it — the grant behind the bookmark no longer holds.
    case folderUnreadable(path: String)
    /// A URL that is not a directory. Opening a photo with Gallery used to land here; a file is not a library.
    case notAFolder(path: String)

    public var description: String {
        switch self {
        case .recycledFolder(let path): "“\(path)” is the Trash. Gallery does not index it."
        case .volumeUnavailable(let path): "The volume holding “\(path)” is not readable."
        case .folderUnreadable(let path): "Gallery lost access to “\(path)”. Pick the folder again to restore it."
        case .notAFolder(let path): "“\(path)” is a file, not a folder. Add the folder that contains it."
        }
    }
}

/// What one pass-A run did. Returned to the caller and logged; the UI reads the progress stream instead.
public struct ScanOutcome: Sendable, Hashable {
    /// Files the walk found.
    public var discovered: Int = 0
    /// Rows the catalog actually accepted, which is what the grid can show.
    public var written: Int = 0
    public var retired: Int = 0
    public var directoriesListed: Int = 0
    public var directoriesRefused: Int = 0
    public var erroredFiles: Int = 0
    /// Set for a cancellation or a refusal — the two reasons a scan did not cover the tree it promised.
    public var failure: String?

    public init() {}
}

/// Runs the indexing pipeline for the folders the user picked.
///
/// The coordinator is an actor and every buffer is actor state, so the two things that touch the same rows
/// — the walk's consumer and the 200 ms flush ticker — cannot both hold one batch. Catalog writes go
/// through the lock-retry ladder, because a second Gallery process holding the write lock is a reason to
/// wait, not a reason to lose 500 rows.
public actor IndexCoordinator {
    public struct Configuration: Sendable {
        /// Rows per transaction: keeps a batch under a millisecond of WAL write while making the reused
        /// prepared statement's savings real.
        public var batchRows: Int
        /// How long rows may sit in the buffer before being written, so a slow volume still paints.
        public var batchInterval: Duration
        /// Parameter count per `DELETE … WHERE id IN (…)`; SQLite caps how many a statement may bind.
        public var sweepChunkRows: Int
        public var enumerator: Enumerator
        /// Kernel-side coalescing for FSEvents, and the quiet period after the last event before a rescan.
        /// Two knobs because they answer different questions: how fast the disk tells us, and how long we
        /// wait for a burst (a folder copy) to finish before walking it.
        public var watchLatency: TimeInterval
        public var watchDebounce: Duration

        public init(batchRows: Int = 500, batchInterval: Duration = .milliseconds(200),
                    sweepChunkRows: Int = 500, enumerator: Enumerator = Enumerator(),
                    watchLatency: TimeInterval = 1.0,
                    watchDebounce: Duration = .seconds(2)) {
            self.batchRows = max(1, batchRows)
            self.batchInterval = batchInterval
            self.sweepChunkRows = max(1, sweepChunkRows)
            self.enumerator = enumerator
            self.watchLatency = watchLatency
            self.watchDebounce = watchDebounce
        }
    }

    private struct Job {
        var task: Task<Void, Never>?
        var ticker: Task<Void, Never>?
        var buffer: [MediaItem] = []
        var isFlushing = false
        var isPaused = false
        var written = 0
        var droppedBatches = 0
        var progress: IndexProgress
    }

    private var watchers: [SourceID: FolderWatcher] = [:]
    private var watcherRoots: [SourceID: URL] = [:]
    private var watchDebounce: [SourceID: Task<Void, Never>] = [:]

    /// A stream retains its watcher, so a watcher nobody stops outlives its owner. Closing the coordinator
    /// (a test fixture, a relaunched app) has to tear the streams down explicitly.
    deinit {
        for watcher in watchers.values { watcher.stop() }
    }

    private let catalog: Catalog
    private let reader: CatalogReader
    private let bookmarks: BookmarkStore
    private let configuration: Configuration
    private let sweeper = Sweeper()

    private var jobs: [SourceID: Job] = [:]
    private let selfWrites: SelfWriteGuard
    private var listeners: [UUID: AsyncStream<IndexProgress>.Continuation] = [:]

    public init(catalog: Catalog, reader: CatalogReader, bookmarks: BookmarkStore = BookmarkStore(),
                configuration: Configuration = Configuration(),
                selfWrites: SelfWriteGuard = SelfWriteGuard()) {
        self.catalog = catalog
        self.reader = reader
        self.bookmarks = bookmarks
        self.configuration = configuration
        self.selfWrites = selfWrites
    }

    // MARK: - Sources

    public func sources() async throws -> [FolderSource] {
        try await catalog.sources()
    }

    /// The folder picker's landing point: refuse the Trash, take the grant, register the source, scan it.
    ///
    /// `BookmarkStore` is the authority for the security-scoped bookmark, and the catalog's `bookmark`
    /// column deliberately stays NULL: the two would be one fact stored twice, disagreeing the first time a
    /// catalog is restored from a backup without the app's preferences.
    @discardableResult
    public func addFolder(_ url: URL, displayName: String? = nil, scanning: Bool = true) async throws -> FolderSource {
        let root = url.standardizedFileURL
        guard !Self.isRecycledFolder(root) else { throw IndexingError.recycledFolder(path: root.path) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw IndexingError.notAFolder(path: root.path)
        }
        guard let volumeID = VolumeIdentity.identifier(for: root) else {
            throw IndexingError.volumeUnavailable(path: root.path)
        }
        try bookmarks.save(root, forKey: Self.bookmarkKey(volumeID: volumeID, path: root.path))
        let source = try await catalog.addSource(
            displayName: displayName ?? root.lastPathComponent,
            rootPath: root.path,
            volumeID: volumeID
        )
        if scanning { startScan(source.id) }
        return source
    }

    public func removeSource(_ id: SourceID) async throws {
        cancelScan(id)
        if let source = try? await reader.source(id: id) {
            bookmarks.remove(Self.bookmarkKey(volumeID: source.volumeID, path: source.rootPath))
        }
        try await catalog.removeSource(id: id)
    }

    /// Relaunch path: turn every stored source into either a browsable one or a badge that says why it is
    /// not, without probing a folder we hold no grant for.
    @discardableResult
    public func resolveSources() async throws -> [FolderSource] {
        var resolved: [FolderSource] = []
        for var source in try await catalog.sources() {
            let key = Self.bookmarkKey(volumeID: source.volumeID, path: source.rootPath)
            switch bookmarks.resolve(key) {
            case .valid(let url):
                source.bookmarkState = reboundState(url, for: source, refreshingBookmark: false, key: key)
            case .stale(let url):
                source.bookmarkState = reboundState(url, for: source, refreshingBookmark: true, key: key)
            case .missing, .failed:
                source.bookmarkState = .needsUserPick
            }
            try await catalog.updateSource(source)
            resolved.append(source)
        }
        return resolved
    }

    /// A bookmark that resolves onto the volume its rows were written for, at a folder that still exists,
    /// is a live source. Re-saving is what re-grants after a reboot.
    private func reboundState(_ url: URL, for source: FolderSource, refreshingBookmark: Bool,
                              key: String) -> BookmarkState {
        // `.stale` covers two different facts — the scope token aged, and the path no longer resolves — and
        // only the second one needs the user. Asking the folder directly is what tells them apart.
        guard (try? url.checkResourceIsReachable()) ?? false else { return .needsUserPick }
        guard VolumeIdentity.identifier(for: url) == source.volumeID else { return .volumeMissing }
        if refreshingBookmark { try? bookmarks.save(url, forKey: key) }
        return .ok
    }

    /// A sandboxed app cannot list the user's Trash, so indexing it and trashing into it are mutually
    /// exclusive operations on one folder — refusing the pick is the only coherent answer.
    private static func isRecycledFolder(_ url: URL) -> Bool {
        let trash = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
        return url.standardizedFileURL.path == trash.path
    }

    static func bookmarkKey(volumeID: String, path: String) -> String { "\(volumeID):\(path)" }

    // MARK: - Scanning

    /// Runs pass A for one source and finishes. Tests await this directly; the UI uses `startScan` and
    /// watches `progressFeed`.
    public func scan(_ sourceID: SourceID) async -> ScanOutcome {
        guard beginJob(sourceID) else {
            var outcome = ScanOutcome()
            outcome.failure = "A scan for this folder is already running."
            return outcome
        }
        let outcome = await run(sourceID)
        endJob(sourceID)
        return outcome
    }

    /// Fire-and-forget for the UI, which learns about progress from the stream rather than an await.
    public func startScan(_ sourceID: SourceID) {
        guard beginJob(sourceID) else { return }
        jobs[sourceID]?.task = Task {
            let outcome = await self.run(sourceID)
            Log.indexing.info("scan \(sourceID.rawValue): found \(outcome.discovered), wrote \(outcome.written), retired \(outcome.retired), refused \(outcome.directoriesRefused), \(outcome.failure ?? "ok")")
            self.endJob(sourceID)
        }
    }

    public func cancelScan(_ sourceID: SourceID) {
        jobs[sourceID]?.task?.cancel()
    }

    // MARK: - Watching

    /// Watch a source the user has granted. Called after a successful resolve: a folder whose grant is gone
    /// has no events to give, and a watcher on a path the sandbox refuses is a silent failure.
    public func startWatching(_ sourceID: SourceID) async {
        guard watchers[sourceID] == nil, let source = try? await reader.source(id: sourceID) else { return }
        guard !source.bookmarkState.blocksScanning else { return }
        let key = Self.bookmarkKey(volumeID: source.volumeID, path: source.rootPath)
        guard case .valid(let root) = bookmarks.resolve(key) else { return }
        // The stream reads the directory for as long as it runs, so the scope is held for that long.
        SecurityScope.begin(root)
        let watcher = FolderWatcher(path: root.path, latency: configuration.watchLatency) { [weak self] in
            Task { await self?.observedChange(sourceID) }
        }
        watchers[sourceID] = watcher
        watcherRoots[sourceID] = root
        watcher.start()
    }

    public func stopWatching(_ sourceID: SourceID) {
        watchDebounce[sourceID]?.cancel()
        watchDebounce[sourceID] = nil
        watchers[sourceID]?.stop()
        watchers[sourceID] = nil
        if let root = watcherRoots.removeValue(forKey: sourceID) { SecurityScope.end(root) }
    }

    public func stopAllWatching() {
        for sourceID in Array(watchers.keys) { stopWatching(sourceID) }
    }

    /// One rescan per burst. A scan already running makes `startScan` refuse, which is exactly right: the
    /// walk in flight will see the new files, and a second one would only race it.
    private func observedChange(_ sourceID: SourceID) {
        // Our own in-place edit fires FSEvents too. Walking the folder for it would be a rescan per edit.
        guard !selfWrites.shouldIgnore() else { return }
        watchDebounce[sourceID]?.cancel()
        watchDebounce[sourceID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.configuration.watchDebounce)
            guard !Task.isCancelled else { return }
            await self.startScan(sourceID)
        }
    }

    /// Pausing stalls the consumer, which backs the walk up through its bounded stream rather than
    /// enumerating into a buffer nobody is writing.
    public func setPaused(_ sourceID: SourceID, _ paused: Bool) {
        guard var job = jobs[sourceID] else { return }
        job.isPaused = paused
        job.progress.isPaused = paused
        jobs[sourceID] = job
        publish(job.progress)
    }

    public func scanningSources() -> [SourceID] { Array(jobs.keys) }

    /// Snapshot for a view that subscribed after the scan started: without it, opening the HUD mid-scan
    /// shows "idle" until the next flush.
    public func latestProgress() -> [IndexProgress] { jobs.values.map(\.progress) }

    /// Live progress, coalesced so a 100k-file walk publishes ten times a second instead of 100,000 times.
    public func progressFeed() -> AsyncStream<IndexProgress> {
        let (stream, continuation) = AsyncStream<IndexProgress>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let token = UUID()
        listeners[token] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeListener(token) }
        }
        return Coalescing(interval: .milliseconds(100)).attach(stream)
    }

    private func removeListener(_ token: UUID) { listeners[token] = nil }

    // MARK: - The run

    /// Claiming the source is synchronous, so two `startScan` calls cannot both believe they own it.
    private func beginJob(_ sourceID: SourceID) -> Bool {
        guard jobs[sourceID] == nil else { return false }
        var job = Job(progress: IndexProgress(sourceID: sourceID, phase: .resolving))
        // The ticker is what makes the 200 ms half of "500 rows / 200 ms" real on a volume that lists one
        // directory every few seconds.
        let interval = configuration.batchInterval
        job.ticker = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.flush(sourceID)
            }
        }
        jobs[sourceID] = job
        return true
    }

    private func endJob(_ sourceID: SourceID) {
        jobs[sourceID]?.ticker?.cancel()
        jobs[sourceID] = nil
    }

    private func run(_ sourceID: SourceID) async -> ScanOutcome {
        guard let source = try? await reader.source(id: sourceID) else {
            return ScanOutcome(failure: "The catalog has no source with id \(sourceID.rawValue).")
        }
        let key = Self.bookmarkKey(volumeID: source.volumeID, path: source.rootPath)
        let root: URL
        switch bookmarks.resolve(key) {
        case .valid(let url), .stale(let url):
            root = url
            try? bookmarks.save(url, forKey: key)
        case .missing:
            return await failed(sourceID, BookmarkState.needsUserPick.userReason, state: .needsUserPick)
        case .failed(let reason):
            return await failed(sourceID, reason, state: .needsUserPick)
        }

        guard let liveVolume = VolumeIdentity.identifier(for: root) else {
            return await failed(sourceID, BookmarkState.volumeMissing.userReason, state: .volumeMissing)
        }
        guard liveVolume == source.volumeID else {
            // Same path, different volume: the rows belong to a card that is not in this slot.
            return await failed(sourceID, BookmarkState.volumeMissing.userReason, state: .volumeMissing)
        }

        // `begin`/`end` rather than `withAccess`: the closure form would have to cross into
        // `SecurityScope`'s non-isolated async context, and Swift 6 rightly refuses to send a closure that
        // captures this actor's `passA`. The pairing still survives a throw, because `end` is in a `defer`.
        SecurityScope.begin(root)
        defer { SecurityScope.end(root) }
        do {
            return try await passA(source: source, root: root)
        } catch let error as IndexingError {
            // The bookmark resolved and the volume matched, yet the walk was refused the folder itself.
            // Re-picking is the only thing that can restore the grant, so that is the badge to show.
            return await failed(sourceID, error.description, state: .needsUserPick)
        } catch {
            return await failed(sourceID, "\(error)", state: .accessDenied)
        }
    }

    /// Pass A: walk, buffer, write, then sweep and queue pass B. Nothing here decodes a pixel.
    private func passA(source: FolderSource, root: URL) async throws -> ScanOutcome {
        let sourceID = source.id
        var outcome = ScanOutcome()
        var seen: Set<String> = []
        var trusted: Set<String> = []
        var refused: Set<String> = []

        advance(sourceID) { $0.phase = .enumerating }
        for await directory in configuration.enumerator.walk(root: root) {
            if Task.isCancelled {
                outcome.failure = "The scan was cancelled."
                break
            }
            await waitWhilePaused(sourceID)

            outcome.directoriesListed += 1
            if directory.isTrustedListing {
                trusted.insert(directory.relativePath)
            } else {
                refused.insert(directory.relativePath)
                outcome.directoriesRefused += 1
            }
            // A refused subtree is survivable: its rows are protected from the sweep and the rest of the
            // folder still indexes. A refused *root* is not — nothing was listed, and reporting a
            // successful scan of zero files leaves the grid claiming the folder is empty when the grant
            // behind it is what went missing.
            if directory.relativePath.isEmpty && !directory.isTrustedListing {
                throw IndexingError.folderUnreadable(path: root.path)
            }
            for entry in directory.entries {
                seen.insert(entry.relativePath)
                if entry.error != .none { outcome.erroredFiles += 1 }
            }
            outcome.discovered += directory.entries.count

            await ingest(directory.entries.map { $0.mediaItem(sourceID: sourceID, volumeID: source.volumeID) },
                         sourceID: sourceID)
        }

        await drain(sourceID: sourceID)
        outcome.written = jobs[sourceID]?.written ?? 0

        // The sweep is per-directory: a refused folder protects its own rows, which is why a scan that hit
        // one EPERM subtree still retires the files that really did vanish elsewhere. Cancelling mid-walk
        // is different — the rest of the tree was never looked at at all.
        if outcome.failure == nil {
            advance(sourceID) { $0.phase = .sweeping }
            let rows = try await catalog.pathRows(sourceID: sourceID)
            let gone = sweeper.vanishedRows(rows, seen: seen, trustedDirectories: trusted,
                                           refusedDirectories: refused)
            outcome.retired = gone.count
            for start in stride(from: 0, to: gone.count, by: configuration.sweepChunkRows) {
                let end = min(start + configuration.sweepChunkRows, gone.count)
                try await catalog.deleteMedia(ids: Array(gone[start..<end]))
            }
        }

        try await catalog.enqueuePendingWork(sourceID: sourceID, priority: 0)
        let queued = try await catalog.queuedWorkCount(sourceID: sourceID)
        if var refreshed = try? await reader.source(id: sourceID) {
            refreshed.lastScan = Date()
            refreshed.bookmarkState = .ok
            try await catalog.updateSource(refreshed)
        }
        advance(sourceID) { progress in
            progress.phase = outcome.failure == nil ? .finished : .failed
            progress.queued = queued
            progress.failed = outcome.erroredFiles
        }
        return outcome
    }

    // MARK: - Buffering

    private func ingest(_ items: [MediaItem], sourceID: SourceID) async {
        guard !items.isEmpty, var job = jobs[sourceID] else { return }
        job.buffer.append(contentsOf: items)
        jobs[sourceID] = job
        if job.buffer.count >= configuration.batchRows { await flush(sourceID) }
    }

    /// Takes whatever is buffered and writes it. One write in flight per source: when the ticker is already
    /// writing, rows stay buffered for the next tick instead of racing it.
    private func flush(_ sourceID: SourceID) async {
        guard var job = jobs[sourceID], !job.isFlushing, !job.buffer.isEmpty else { return }
        let batch = job.buffer
        job.buffer = []
        job.isFlushing = true
        jobs[sourceID] = job
        await write(batch, sourceID: sourceID)
    }

    private func write(_ batch: [MediaItem], sourceID: SourceID) async {
        var burned = 0
        var rows = 0
        var reason: String?
        while true {
            do {
                rows = try await catalog.recordEnumeration(batch).count
                break
            } catch let error as SQLiteError where error.isLockContention {
                guard burned < LockBackoff.maximumAttempts, !Task.isCancelled else {
                    reason = "dropped a \(batch.count)-row batch after \(burned) lock retries: \(error)"
                    break
                }
                burned += 1
                try? await Task.sleep(for: LockBackoff.delay(afterAttempt: burned - 1) + LockBackoff.jitter())
            } catch {
                reason = "enumeration batch failed: \(error)"
                break
            }
        }

        // One tail update, re-reading the job because the walk may have appended while this was in flight.
        if var job = jobs[sourceID] {
            job.isFlushing = false
            if reason == nil {
                job.written += rows
                job.progress.discovered += rows
            } else {
                job.droppedBatches += 1
            }
            jobs[sourceID] = job
            publish(job.progress)
        }
        if let reason { Log.indexing.error("\(reason, privacy: .public)") }
    }

    /// Waits for the buffer to reach the catalog, including the batch another task is mid-write on.
    private func drain(sourceID: SourceID) async {
        for _ in 0..<400 {
            guard let job = jobs[sourceID], !job.buffer.isEmpty || job.isFlushing else { return }
            await flush(sourceID)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitWhilePaused(_ sourceID: SourceID) async {
        while jobs[sourceID]?.isPaused == true, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Progress

    private func advance(_ sourceID: SourceID, _ change: (inout IndexProgress) -> Void) {
        guard var job = jobs[sourceID] else { return }
        change(&job.progress)
        jobs[sourceID] = job
        publish(job.progress)
    }

    private func publish(_ progress: IndexProgress) {
        for listener in listeners.values { listener.yield(progress) }
    }

    private func failed(_ sourceID: SourceID, _ reason: String, state: BookmarkState) async -> ScanOutcome {
        // A badge we could not write is better than a folder that is unreachable and looks fine, so these
        // catalog hops are allowed to fail silently.
        if var source = try? await reader.source(id: sourceID) {
            source.bookmarkState = state
            try? await catalog.updateSource(source)
        }
        advance(sourceID) { $0.phase = .failed }
        Log.indexing.error("scan \(sourceID.rawValue) failed: \(reason, privacy: .public)")
        return ScanOutcome(failure: reason)
    }
}

private extension ScanOutcome {
    init(failure: String) {
        self.init()
        self.failure = failure
    }
}
