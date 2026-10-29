import Foundation
import CoreGraphics
import Observation
import GalleryAnalysis
import GalleryDomain
import GalleryCatalog
import GalleryEditing
import GalleryIndexing

/// Something the user should be told about, once, in the UI rather than only in the log.
public struct Notice: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var text: String
    public var detail: String?

    public init(_ text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }
}

/// Panels the library cannot host itself: the App target owns `NSOpenPanel`, and the grid and the cells only
/// need to know that asking for one is a thing that can happen.
public struct MediaLibraryActions: Sendable {
    public var exportCopies: @MainActor @Sendable ([MediaID]) async -> Void

    public init(exportCopies: @escaping @MainActor @Sendable ([MediaID]) async -> Void) {
        self.exportCopies = exportCopies
    }
}

/// The view model behind the library window: the read side of the catalog, the coordinator's progress,
/// and the keyset cursor the grid is paging with.
///
/// Every catalog hop is `await`ed against an actor, so scrolling, scanning and writing never share a
/// thread with the render loop. The generation counter is the part that keeps that honest: two taps on the
/// sidebar start two page loads, and the slower one must not win.
@MainActor
@Observable
public final class MediaLibraryModel {
    public private(set) var sources: [FolderSource] = []
    public private(set) var items: [MediaItem] = []
    public private(set) var selection: AlbumKind = .all
    public private(set) var isLoadingPage = false
    public private(set) var hasMorePages = false
    public private(set) var rowCount = 0
    public private(set) var progress: [SourceID: IndexProgress] = [:]
    /// Pass B's numbers, kept apart from the walk's because they answer a different question: pass A says how
    /// many files a folder holds, pass B says how many of them the grid has something to draw yet.
    public private(set) var previews: [SourceID: IndexProgress] = [:]
    public var notices: [Notice] = []

    /// Set by the toolbar's sort menu. A `var` on purpose: it is the user's choice, not derived state.
    public var sort: MediaSort = .default

    /// The tile(s) the user clicked, and the photo the viewer is showing. `selectedID` is the primary — the
    /// one the inspector describes and Return opens — and `selectedIDs` is everything a batch action touches.
    /// Ids rather than copied rows: pass B fills in a pixel size minutes after a page lands, and a snapshot
    /// would leave the inspector describing a row that no longer exists in that shape.
    public private(set) var selectedIDs: Set<MediaID> = []
    public private(set) var selectedID: MediaID?
    private var selectionAnchor: MediaID?
    public private(set) var viewerID: MediaID?
    /// The photo open in the editor. Nil when the editor is closed; the session lives here rather than in
    /// the view so a SwiftUI rebuild cannot drop an undo stack.
    public private(set) var editingSession: EditingSession?
    public var editorID: MediaID? { editingSession?.source.mediaID }
    /// The collage being composed, if any. Kept apart from the editor: a collage is a document over several
    /// photos, and closing one must not close the other.
    public private(set) var collageSession: CollageSession?
    public var isCollageOpen: Bool { collageSession != nil }
    /// The trailing inspector. Open by default, because "what is this photo" is the question a gallery
    /// exists to answer, not a power feature.
    public var isInspectorPresented = true
    /// Which columns the split view is showing, driven by ⌘1/⌘2.
    public var panels: PanelLayout = .all

    public enum PanelLayout: Sendable { case all, detailOnly }

    /// Trash is emptied after this long, the same month Finder's Trash keeps things. Manual Delete Forever
    /// exists for people who would rather not wait.
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Date shelves, from the catalog: days keep only buckets with enough photos to be a real day.
    public private(set) var days: [Album] = []
    public private(set) var months: [Album] = []
    /// Place albums. A cluster nobody has named yet still appears, titled by its coordinates.
    public private(set) var places: [Album] = []
    /// Tag albums from the analysis pass, and the pass's own numbers (kept apart from the drain's so a
    /// finished analysis cannot mask an active scan in the HUD).
    public private(set) var tags: [Album] = []
    /// Face clusters with enough photos to be a person. Numbered until somebody names them.
    public private(set) var people: [Album] = []
    /// The best shot of every duplicate set, loaded while the Duplicates album is open so a cell can say so.
    public private(set) var duplicateBests: Set<MediaID> = []
    public private(set) var analysisProgress: [SourceID: IndexProgress] = [:]
    private var analysisFeed: Task<Void, Never>?
    /// One level of folder albums per source, keyed by the source they belong to.
    public private(set) var subfolders: [SourceID: [Album]] = [:]

    /// The snippet each search hit matched on, so a result can show *why* it is in the list.
    public private(set) var searchSnippets: [MediaID: String] = [:]

    /// What the search field shows, and what its last settled keystroke actually searched for. Two properties
    /// because typing must not wait for SQLite, and a half-typed word must not replace the grid.
    public var searchFieldText = ""
    public private(set) var appliedSearch = ""
    public var isSearching: Bool { !appliedSearch.isEmpty }
    private var searchTask: Task<Void, Never>?
    private static let searchLimit = 500

    /// Rows per page. 200 is roughly three screens of tiles, which is what makes the first page arrive
    /// before the scan has listed the tenth directory.
    private static let pageSize = 200

    private let reader: CatalogReader
    private let coordinator: IndexCoordinator
    private let passB: MetadataWorker
    private let thumbnails: ThumbnailService
    private let catalog: Catalog
    private let resolver: any MediaResolving
    /// Files behind the cells that have been on screen. A window report already resolves them for the
    /// thumbnail window; keeping the answer is what makes a drag to Finder synchronous.
    private var knownURLs: [MediaID: URL] = [:]
    /// The clips the viewer has open. Owned by the model rather than the view so a SwiftUI rebuild cannot
    /// silently orphan a playing `AVPlayer`.
    private let players: PlayerPool
    private let trash: TrashService
    private let locations: LocationDeriver
    /// Nil when the caller does not want a third pass at all — every unit test, and any future build that
    /// ships without Vision. The app always passes one.
    private let analysis: AnalysisWorker?
    /// Nil in unit tests and anywhere the editor is not part of the build; the app always passes one.
    private let editor: EditService?
    /// Set by the composition root; nil in tests, which is why every caller treats it as optional.
    public var actions: MediaLibraryActions?
    private var cursor: SortCursor?
    private var generation = 0
    private var feed: Task<Void, Never>?
    private var previewFeed: Task<Void, Never>?
    private var lastEmptyFill: SuspendingClock.Instant?
    /// Which cells the grid has on screen. Membership rather than an ordered list, because the order the
    /// service prefetches in is the order of `items` — the one thing a scroll gesture cannot get wrong.
    private var visibleCells: Set<MediaID> = []
    private var windowFlush: Task<Void, Never>?

    public init(reader: CatalogReader, coordinator: IndexCoordinator, passB: MetadataWorker,
                thumbnails: ThumbnailService, catalog: Catalog, resolver: any MediaResolving,
                trashRoot: URL, geocoder: any ReverseGeocoding = AppleGeocoder(),
                analysis: AnalysisWorker? = nil, editor: EditService? = nil) {
        self.reader = reader
        self.coordinator = coordinator
        self.passB = passB
        self.thumbnails = thumbnails
        self.catalog = catalog
        self.resolver = resolver
        self.players = PlayerPool(resolver: resolver)
        self.trash = TrashService(catalog: catalog, resolver: resolver, root: trashRoot)
        self.locations = LocationDeriver(catalog: catalog, geocoder: geocoder)
        self.analysis = analysis
        self.editor = editor
    }

    // MARK: - Lifecycle

    /// Relaunch path. Resolves the stored bookmarks first so a folder the user has to re-pick is badged
    /// before the grid asks for it, then resumes the scan of everything still reachable.
    public func start() async {
        // Both feeds are attached before anything is set in motion, so a scan or a drain resuming in the next
        // lines has somewhere to report to. Unwrapping `self` per iteration keeps a model the window closed
        // from being held alive by its own feed.
        let posterStream = await passB.progressFeed()
        previewFeed = Task { [weak self] in
            for await update in posterStream {
                guard let self else { return }
                let was = self.previews[update.sourceID]
                self.previews[update.sourceID] = update
                // A poster is a new fact about a row the grid already shows — its aspect ratio, its date, the
                // text search can find — so the page has to be read again once the drain says it is done.
                // Only on a change: a small folder's first and only frame can already be "finished", and a
                // repeated frame of the same numbers is not a new answer worth throwing away a cursor for.
                if update.phase == .finished, update != was {
                    // Capture dates are what the day and month shelves are made of, and the drain is what
                    // writes them. GPS arrives the same way, and the places shelf is derived from it.
                    await self.refreshAlbums()
                    await self.refreshPlaces()
                    await self.reload()
                }
            }
        }

        // The third pass reports through its own feed. It runs behind pass B (the worker's gate), so starting
        // it here is a promise rather than a race: it will idle until the drain says it is done.
        if let analysis {
            let analysisStream = await analysis.progressFeed()
            analysisFeed = Task { [weak self] in
                for await update in analysisStream {
                    guard let self else { return }
                    let was = self.analysisProgress[update.sourceID]
                    self.analysisProgress[update.sourceID] = update
                    if update.phase == .finished, update != was {
                        // Tags and recognised text are only worth a shelf refresh once a source is done: the
                        // shelf is a handful of rows, but re-reading it on every 100 ms frame would be churn
                        // for a count nobody can watch climb.
                        await self.refreshTags()
                        await self.reload()
                    }
                }
            }
        }

        let stream = await coordinator.progressFeed()
        feed = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                self.progress[update.sourceID] = update
                if update.phase == .finished || update.phase == .failed {
                    await self.refreshSources()
                    await self.refreshAlbums()
                    await self.reload()
                    // The walk just queued files pass B has never seen. If its previous drain ended with an
                    // empty queue, nothing else would start another one.
                    await self.passB.start()
                } else if self.items.isEmpty && update.phase.isCounting && self.dueForEmptyFill() {
                    // Pass A writes rows continuously, so an empty grid is not a finished answer while a
                    // scan is running. Poll on a one-second beat until the first page exists; after that
                    // scrolling drives the paging and the only refresh left is the one at the end.
                    await self.reload()
                }
            }
        }

        // Pass B drains while pass A still walks: the queue it claims from is written before the rows are
        // enqueued, so there is nothing half-made to read, and a folder the walk is still listing is a folder
        // whose first pages could already have posters.
        await passB.start()
        await analysis?.start()
        try? await catalog.pruneDuplicateGroups()
        await purgeExpiredTrash()
        if let editor {
            let interrupted = await editor.recoverInterruptedEdits()
            if interrupted > 0 {
                notices.append(Notice(
                    interrupted == 1
                        ? "An earlier version is available for one photo."
                        : "Earlier versions are available for \(interrupted) photos.",
                    detail: "Use Revert to Previous Version on the photo to restore it."
                ))
            }
            let cutoff = Date().addingTimeInterval(-Self.trashRetention)
            _ = await editor.purgeExpiredBackups(olderThan: cutoff)
        }

        do {
            let resolved = try await coordinator.resolveSources()
            for source in resolved where !source.bookmarkState.blocksScanning && source.isIncluded {
                await coordinator.startScan(source.id)
                // A folder that is being scanned is also a folder worth watching: the scan covers what is
                // there now, the watcher covers what the user drops in ten seconds later.
                await coordinator.startWatching(source.id)
            }
        } catch {
            notices.append(Notice("Could not reopen the library.", detail: "\(error)"))
        }
        await refreshSources()
        await refreshAlbums()
        await refreshPlaces()
        await refreshTags()
        await reload()

    }

    /// The tag shelf, from the analysis pass. Cheap by construction: one grouped count over a small table.
    public func refreshTags() async {
        tags = (try? await reader.tagAlbums()) ?? []
        people = (try? await reader.peopleAlbums()) ?? []
    }

    /// A person's name is the user's, and a re-analysis never overwrites it: renaming writes the row the
    /// People shelf reads, and nothing else touches that column.
    public func renamePerson(_ album: Album, to name: String) async {
        guard case .person(let key) = album.kind else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await catalog.renameFaceCluster(id: key.stableID, name: trimmed.isEmpty ? nil : trimmed)
            await refreshTags()
        } catch {
            notices.append(Notice("That person could not be named.", detail: "\(error)"))
        }
    }

    public func hidePerson(_ album: Album) async {
        guard case .person(let key) = album.kind else { return }
        do {
            try await catalog.setFaceClusterHidden(id: key.stableID, hidden: true)
            await refreshTags()
        } catch {
            notices.append(Notice("That person could not be hidden.", detail: "\(error)"))
        }
    }

    /// The one action the Duplicates album offers: keep the set's best shot, move the rest to the trash the
    /// user can restore from. Never automatic — the app proposes, the user disposes.
    public func keepBestAndTrashRest(around item: MediaItem) async {
        guard let set = try? await reader.duplicateSet(containing: item.id) else { return }
        let duplicates = set.members.filter { $0 != set.best }
        guard !duplicates.isEmpty else { return }
        await moveToTrash(duplicates)
    }

    public func isDuplicateBest(_ item: MediaItem) -> Bool {
        duplicateBests.contains(item.id)
    }

    /// The picture a sidebar row shows beside its name. Served from the grid poster that pass B already baked,
    /// so a shelf full of covers costs a disk read each rather than a decode of every original.
    public func coverPreview(for album: Album) async -> CGImage? {
        guard let id = album.coverMediaID else { return nil }
        let item: MediaItem?
        if let shown = items.first(where: { $0.id == id }) {
            item = shown
        } else {
            item = try? await reader.item(id: id)
        }
        guard let item else { return nil }
        return await thumbnails.image(.init(item: item), bucket: .gridLarge)
    }

    /// Pause/resume the third pass. The worker publishes a snapshot when it changes, so the HUD follows
    /// without this method having to guess.
    public func setAnalysisPaused(_ paused: Bool) async {
        await analysis?.setPaused(paused)
    }

    public var analysisPaused: Bool {
        analysisProgress.values.contains { $0.isPaused }
    }

    /// Whether this process runs a third pass at all. The menu hides its items when it does not.
    public var hasAnalysis: Bool { analysis != nil }

    /// Drop every derived analysis row and walk the library again. Explorer-level, deliberately a menu item
    /// rather than something a scan triggers.
    public func reanalyzeLibrary() async {
        guard let analysis else { return }
        do {
            try await analysis.reanalyze()
        } catch {
            notices.append(Notice("The library could not be re-analysed.", detail: "\(error)"))
        }
    }

    /// Explorer-level repair for a search index that has drifted: rebuild it from the media table. Cheap at
    /// a few thousand rows, a second or two at a hundred thousand — offered as a menu item, never automatic.
    public func rebuildSearchIndex() async {
        do {
            try await catalog.rebuildFTS()
            notices.append(Notice("The search index was rebuilt."))
        } catch {
            notices.append(Notice("The search index could not be rebuilt.", detail: "\(error)"))
        }
    }

    /// Days and months are derived from pass B's capture dates, so a scan that just started is a sidebar
    /// with no dates in it yet — the feed refreshes these when a pass reports new rows.
    ///
    /// Both queries run before either shelf is replaced: a UI that updates between the two awaits would
    /// render a sidebar with days and no months for one frame.
    public func refreshAlbums() async {
        let freshDays = (try? await reader.dateAlbums()) ?? []
        let freshMonths = (try? await reader.monthAlbums()) ?? []
        days = freshDays
        months = freshMonths
    }

    /// Places are derived, not queried: the deriver re-runs the clusterer over every geotagged row, carries
    /// existing names forward, and names what it can reach. Offline this still produces albums — titled by
    /// coordinate — which is the promise that makes geocoding a refinement rather than a dependency.
    public func refreshPlaces() async {
        _ = await locations.refresh()
        places = (try? await reader.locationAlbums()) ?? []
    }

    public func stop() {
        // Closing the window is the end of playback, and it must not wait for the drain to land a batch.
        players.stopAll()
        editingSession?.cancel()
        editingSession = nil
        collageSession?.cancel()
        collageSession = nil
        feed?.cancel()
        feed = nil
        previewFeed?.cancel()
        previewFeed = nil
        analysisFeed?.cancel()
        analysisFeed = nil
        windowFlush?.cancel()
        windowFlush = nil
        // Not awaited: `stop` is the window's `onDisappear`, and a drain that is mid-decode lands its batch
        // rather than being cut off. The worker stops claiming new rows here either way.
        let worker = passB
        let cache = thumbnails
        let walk = coordinator
        let analyser = analysis
        Task {
            await walk.stopAllWatching()
            await worker.cancel()
            await analyser?.cancel()
            await cache.clearWindow()
        }
    }

    /// One-second beat, monotonic so a clock change cannot stall the first page.
    private func dueForEmptyFill() -> Bool {
        let now = SuspendingClock.now
        if let last = lastEmptyFill, now < last.advanced(by: .seconds(1)) { return false }
        lastEmptyFill = now
        return true
    }

    // MARK: - Sources

    public func refreshSources() async {
        sources = (try? await reader.sources()) ?? []
        // One level of folder albums per source. The reader derives them from `parent_rel`, so a new
        // subfolder shows up here as soon as the walk has written its rows.
        var fresh: [SourceID: [Album]] = [:]
        for source in sources {
            fresh[source.id] = (try? await reader.albums(of: .folder(source.id))) ?? []
        }
        subfolders = fresh
    }

    /// The folder picker's destination: grant, register, scan. Several at once, because the panel allows it
    /// and one refused folder must not stop the others from registering.
    public func add(_ urls: [URL]) async {
        for url in urls { await add(url) }
    }

    public func add(_ url: URL) async {
        do {
            let source = try await coordinator.addFolder(url)
            selection = .folder(source.id)
            await coordinator.startWatching(source.id)
            await refreshSources()
            await refreshAlbums()
            await reload()
        } catch {
            notices.append(Notice("Could not add “\(url.lastPathComponent)”.", detail: "\(error)"))
        }
    }

    public func rescan(_ sourceID: SourceID) async {
        await coordinator.startScan(sourceID)
        await refreshSources()
    }

    /// ⌘R. Folders that lost their grant are skipped rather than retried — nothing the user can do from a
    /// keyboard fixes a revoked permission, and a loop of doomed scans would look like a hang.
    public func rescanAll() async {
        for source in sources where !source.bookmarkState.blocksScanning && source.isIncluded {
            await rescan(source.id)
        }
    }

    public func remove(_ source: FolderSource) async {
        do {
            await coordinator.stopWatching(source.id)
            try await coordinator.removeSource(source.id)
            if case .folder(let id) = selection, id == source.id { selection = .all }
            if case .subfolder(let id, _) = selection, id == source.id { selection = .all }
            progress[source.id] = nil
            previews[source.id] = nil
            await refreshSources()
            await reload()
        } catch {
            notices.append(Notice("Could not remove “\(source.displayName)”.", detail: "\(error)"))
        }
    }

    public func setPaused(_ sourceID: SourceID, _ paused: Bool) async {
        await coordinator.setPaused(sourceID, paused)
        if let snapshot = await coordinator.latestProgress().first(where: { $0.sourceID == sourceID }) {
            progress[sourceID] = snapshot
        }
    }

    public func cancelScan(_ sourceID: SourceID) async {
        await coordinator.cancelScan(sourceID)
    }

    // MARK: - Paging

    public func select(_ album: AlbumKind) async {
        guard album != selection else { return }
        selection = album
        // The rows behind the viewer are about to be a different set; a selection that survived would be a
        // photo the user can no longer see. A search belongs to the album it was typed in, so it goes too.
        selectedIDs = []
        selectedID = nil
        selectionAnchor = nil
        viewerID = nil
        clearSearch()
        // The old album's rows must not sit under the new album's title for even one frame.
        items = []
        await reload()
    }

    // MARK: - Search

    /// Typing is debounced: 200 ms after the last keystroke, one query. The field keeps the raw text so it
    /// never lags behind the keyboard.
    public func updateSearch(_ text: String) {
        searchFieldText = text
        searchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchTask = nil
            guard isSearching else { return }
            appliedSearch = ""
            searchSnippets = [:]
            Task { await self.reload() }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.runSearch(query)
        }
    }

    /// Search is scoped to the album it was typed in: the field sits in that album's toolbar, and a filter
    /// that silently reached across the whole library would make "Problems" and "Favorites" mean nothing.
    /// Selecting "All Media" is how the user asks for the whole library.
    private func runSearch(_ query: String) async {
        generation += 1
        let stamp = generation
        do {
            let hits = try await reader.search(query, within: selection, prefix: true,
                                               limit: Self.searchLimit)
            guard stamp == generation, !Task.isCancelled else { return }
            appliedSearch = query
            cursor = nil
            hasMorePages = false
            items = hits.map(\.item)
            rowCount = items.count
            searchSnippets = Dictionary(hits.map { ($0.item.id, $0.snippet) },
                                        uniquingKeysWith: { first, _ in first })
            // The rows behind the results are a different set, so a selection from the previous query is
            // not something the user can still see.
            selectedIDs = selectedIDs.intersection(Set(items.map(\.id)))
            if let selectedID, !selectedIDs.contains(selectedID) { self.selectedID = selectedIDs.first }
            visibleCells = visibleCells.intersection(Set(items.map(\.id)))
        } catch {
            guard stamp == generation else { return }
            notices.append(Notice("The search could not be run.", detail: "\(error)"))
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchFieldText = ""
        appliedSearch = ""
        searchSnippets = [:]
    }

    /// Restart the cursor and fetch the first page.
    public func reload() async {
        // A reload triggered by a scan or a drain must not throw the user's search results away — it re-runs
        // the same search, which is what "new rows landed" means while a filter is on.
        if isSearching {
            await runSearch(appliedSearch)
            return
        }
        generation += 1
        let stamp = generation
        cursor = nil
        isLoadingPage = true
        defer { if stamp == generation { isLoadingPage = false } }

        do {
            rowCount = try await reader.count(album: selection)
            let page = try await reader.page(album: selection, sort: sort, limit: Self.pageSize)
            guard stamp == generation else { return }
            // Replace rather than clear-then-fill: a scan finishing in the background re-runs this while the
            // user is looking at the page, and blanking the grid first is a flash of "no photos" for as long
            // as the query takes.
            items = page.items
            cursor = page.nextCursor
            hasMorePages = page.hasMore
            // The Duplicates album badges the keeper of each set, so the set has to be read whenever that
            // album is the one on screen — one query over a tiny table, not per cell.
            if selection == .duplicates {
                duplicateBests = Set((try? await reader.bestDuplicateIDs()) ?? [])
            } else if !duplicateBests.isEmpty {
                duplicateBests = []
            }
            // A fresh page can be a different set of rows, and a cell that left the album is not on screen
            // just because SwiftUI kept its view alive. Without this the window keeps prefetching pictures
            // the user switched away from.
            let stillOnScreen = Set(page.items.map(\.id))
            // A selection (or a known file URL) that is no longer on the page is a row the user cannot act
            // on; keeping it would make ⌘⌫ delete something that is not visible.
            selectedIDs = selectedIDs.intersection(stillOnScreen)
            if let selectedID, !stillOnScreen.contains(selectedID) { self.selectedID = selectedIDs.first }
            if let anchor = selectionAnchor, !stillOnScreen.contains(anchor) {
                selectionAnchor = selectedIDs.first
            }
            knownURLs = knownURLs.filter { stillOnScreen.contains($0.key) }
            let leftTheAlbum = visibleCells.subtracting(stillOnScreen)
            if !leftTheAlbum.isEmpty {
                visibleCells = stillOnScreen.intersection(visibleCells)
                scheduleWindowReport()
            }
        } catch {
            guard stamp == generation else { return }
            notices.append(Notice("This album could not be read.", detail: "\(error)"))
        }
    }

    /// Called by the grid when the last visible cell is near the end of what is loaded.
    public func loadMore() async {
        guard hasMorePages, !isLoadingPage, !isSearching, let cursor else { return }
        generation += 1
        let stamp = generation
        isLoadingPage = true
        defer { if stamp == generation { isLoadingPage = false } }

        do {
            let page = try await reader.page(album: selection, sort: sort, after: cursor, limit: Self.pageSize)
            guard stamp == generation else { return }
            items.append(contentsOf: page.items)
            self.cursor = page.nextCursor
            hasMorePages = page.hasMore
        } catch {
            guard stamp == generation else { return }
            notices.append(Notice("The next page could not be read.", detail: "\(error)"))
        }
    }

    // MARK: - Cells

    /// The picture for one cell, from the cheapest tier that holds it: memory, then the cache file, then a
    /// decode. Nil is the answer for a file that cannot be drawn, and the cell keeps its placeholder.
    public func preview(for item: MediaItem) async -> CGImage? {
        await thumbnails.image(.init(item: item), bucket: .gridLarge)
    }

    /// The grid's `onAppear` for a tile. A flick across a thousand photos must cost one window report, not a
    /// thousand, so the report waits for the scrolling to settle before it reaches the cache or the queue.
    public func cellAppeared(_ item: MediaItem) {
        guard visibleCells.insert(item.id).inserted else { return }
        scheduleWindowReport()
    }

    public func cellDisappeared(_ item: MediaItem) {
        guard visibleCells.remove(item.id) != nil else { return }
        scheduleWindowReport()
    }

    private func scheduleWindowReport() {
        windowFlush?.cancel()
        windowFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.windowSettle)
            guard !Task.isCancelled, let self else { return }
            await self.reportWindow()
        }
    }

    private func reportWindow() async {
        let shown = items.filter { visibleCells.contains($0.id) }
        await thumbnails.setWindow(shown.map { .init(item: $0) }, bucket: .gridLarge)
        await passB.raisePriority(mediaIDs: shown.map(\.id))
        // The same query the pixel service would make, kept: a drag to Finder has to answer synchronously,
        // and "where is this file" is already known for every cell the user can see.
        let targets = await resolver.targets(for: shown.map(\.id))
        for (id, target) in targets { knownURLs[id] = target.url }
    }

    /// The file behind a cell, for dragging it out. Nil until the cell has been on screen once; a drag from
    /// a cell that has never reported has no URL to offer, and Finder shows nothing rather than a dead file.
    public func fileURL(for item: MediaItem) -> URL? { knownURLs[item.id] }

    /// A flick has to land on a picture, and a settled scroll reads like a flick to nothing but a timer.
    /// Long enough that one gesture is one report, short enough that the decode lane starts on the row the
    /// user stopped on before they have finished reading the tile they were looking at.
    private static let windowSettle = Duration.milliseconds(120)

    // MARK: - Selection and the viewer

    /// The row the inspector is about, resolved against the page the grid is showing rather than remembered,
    /// so pass B landing a pixel size updates the inspector along with the cell.
    public var selectedItem: MediaItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    /// Everything a batch action touches, in page order.
    public var selectedItems: [MediaItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    public var selectedMediaIDs: [MediaID] { selectedItems.map(\.id) }

    public var viewerItem: MediaItem? {
        guard let viewerID else { return nil }
        return items.first { $0.id == viewerID }
    }

    /// A click, ⌘-click or ⇧-click. The anchor is the last row clicked without ⇧ — the range a ⇧-click
    /// extends from is the one the user built up, not the alphabetically nearest one.
    public func select(_ id: MediaID?, extending: Bool = false, range: Bool = false) {
        guard let id, items.contains(where: { $0.id == id }) else {
            selectedIDs = []
            selectedID = nil
            selectionAnchor = nil
            return
        }
        if range, let anchor = selectionAnchor,
           let start = items.firstIndex(where: { $0.id == anchor }),
           let end = items.firstIndex(where: { $0.id == id }) {
            let bounds = start <= end ? start...end : end...start
            selectedIDs = Set(items[bounds].map(\.id))
            selectedID = id
        } else if extending {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
                if selectedID == id { selectedID = selectedIDs.isEmpty ? nil : items.last { selectedIDs.contains($0.id) }?.id }
            } else {
                selectedIDs.insert(id)
                selectedID = id
            }
            selectionAnchor = id
        } else {
            selectedIDs = [id]
            selectedID = id
            selectionAnchor = id
        }
    }

    /// ⌘A. The whole loaded page, not the whole library: a shortcut that silently selected a hundred
    /// thousand rows the grid has never drawn would make ⌘⌫ unthinkable.
    public func selectAll() {
        guard !items.isEmpty else { return }
        selectedIDs = Set(items.map(\.id))
        selectedID = items.first?.id
        selectionAnchor = items.first?.id
    }

    /// Double-click, or Return on the selection. Selection follows the viewer, so closing it leaves the
    /// inspector on the photo the user was just looking at.
    public func openViewer(_ id: MediaID) {
        guard items.contains(where: { $0.id == id }) else { return }
        selectedIDs = [id]
        selectedID = id
        selectionAnchor = id
        viewerID = id
    }

    public func closeViewer() {
        viewerID = nil
        // A clip that is still decoding is a clip that will play its audio over the grid the moment it
        // reaches a keyframe. Closing is the end of playback, not a pause the user has to find.
        players.stopAll()
    }

    /// ←/→. Stops at the ends rather than wrapping — a viewer that jumps from the oldest photo to the newest
    /// reads as a bug — and pulls the next page in when stepping past what is loaded.
    public func stepViewer(by delta: Int) async {
        guard let viewerID, let current = items.firstIndex(where: { $0.id == viewerID }) else { return }
        if delta > 0, current == items.count - 1, hasMorePages {
            await loadMore()
        }
        guard let landed = items.firstIndex(where: { $0.id == viewerID }) else { return }
        let next = min(max(landed + delta, 0), items.count - 1)
        guard next != landed else { return }
        self.viewerID = items[next].id
        selectedIDs = [items[next].id]
        selectedID = items[next].id
        selectionAnchor = self.viewerID
        // Whatever the previous step opened is stopped before its layer is replaced.
        players.evict(except: self.viewerID)
    }

    /// The clip's player, made on first ask and kept inside the pool's window.
    public func videoLease(for item: MediaItem) async -> PlayerPool.Lease? {
        await players.player(for: item)
    }

    /// Opens the next clip before the user asks for it, so one press of → does not pay a cold asset load.
    public func preloadVideo(after item: MediaItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index + 1 < items.count else { return }
        let next = items[index + 1]
        guard next.kind == .video else { return }
        _ = await players.player(for: next)
    }

    /// The viewer's tier: one decode down to at most 2048 px, which a 1280-px camera file passes through
    /// untouched and a 48 MP frame pays for once and keeps on disk.
    public func viewerImage(for item: MediaItem) async -> CGImage? {
        await thumbnails.image(.init(item: item), bucket: .viewerFull)
    }

    // MARK: - Editing

    public var hasEditor: Bool { editor != nil }

    /// Whether the editor can open this row right now: a photo whose pixels pass B has already read.
    public func canEdit(_ item: MediaItem) -> Bool {
        editor != nil && item.kind == .image && item.pixelSize != nil
    }

    /// Opens the editor over the grid. Opening from the viewer keeps the viewer behind it, so closing the
    /// editor returns to the same photo; opening from a tile does not open the viewer behind the editor.
    public func openEditor(_ id: MediaID, tool: EditorTool = .crop) async {
        guard let editor else { return }
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard item.kind == .image else {
            notices.append(Notice("Only photos can be edited."))
            return
        }
        guard let stored = item.pixelSize else {
            notices.append(Notice("This photo is still being read.", detail: "Try again in a moment."))
            return
        }
        if editingSession?.source.mediaID == id { return }
        editingSession?.cancel()
        guard let source = await editor.source(for: item) else {
            notices.append(Notice("The file behind “\(item.name)” could not be found."))
            return
        }
        selectedIDs = [id]
        selectedID = id
        selectionAnchor = id
        let session = EditingSession(
            source: source, storedSize: stored, orientation: item.orientation ?? 1, service: editor
        )
        editingSession = session
        await session.loadPreview()
        session.setTool(tool)
    }

    /// When the newest restorable backup was made, for the inspector's affordance.
    public func previousVersion(for id: MediaID) async -> Date? {
        await editor?.backupDate(for: id)
    }

    public func closeEditor() {
        editingSession?.cancel()
        editingSession = nil
    }

    /// Writes the fields into the files themselves, one row at a time. A failure on one row does not stop
    /// the others, and the notice names the first reason.
    @discardableResult
    public func applyMetadata(_ overrides: MetadataOverrides, to ids: [MediaID]) async -> Bool {
        guard let editor, !overrides.isEmpty else { return false }
        let chosen = items.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return false }
        var written = 0
        var failure: String?
        for item in chosen {
            let outcome = await editor.applyMetadata(overrides, to: item)
            if outcome.written {
                written += 1
            } else if failure == nil {
                failure = outcome.message
            }
        }
        guard written > 0 else {
            notices.append(Notice("The metadata could not be written.", detail: failure))
            return false
        }
        notices.append(Notice(
            written == 1 ? "Metadata written to the file." : "Metadata written to \(written) files.",
            detail: failure
        ))
        await refreshAlbums()
        await refreshPlaces()
        await reload()
        await editingSession?.reloadFileMetadata()
        return true
    }

    // MARK: - Replace and revert

    /// The explicit, destructive half of the editor. The service keeps a previous version first, so this
    /// can always be undone from inside the app.
    public func replaceEditorOriginal() async {
        guard let editor, let session = editingSession,
              let item = items.first(where: { $0.id == session.source.mediaID }) else { return }
        let outcome = await editor.replaceOriginal(item, recipe: session.recipe)
        guard outcome.replaced else {
            notices.append(Notice("The original was not replaced.", detail: outcome.message))
            return
        }
        notices.append(Notice(
            "The original was replaced.",
            detail: "A previous version is kept for 30 days; use Revert to Previous Version to restore it."
        ))
        closeEditor()
        await reload()
        await refreshAlbums()
        await refreshPlaces()
    }

    public func revertEditorOriginal() async {
        guard let editor, let session = editingSession,
              let item = items.first(where: { $0.id == session.source.mediaID }) else { return }
        let outcome = await editor.revertToPreviousVersion(item)
        guard outcome.replaced else {
            notices.append(Notice("Nothing was restored.", detail: outcome.message))
            return
        }
        notices.append(Notice("The previous version was restored."))
        closeEditor()
        await reload()
        await refreshAlbums()
        await refreshPlaces()
    }

    public func revertToPreviousVersion(_ item: MediaItem) async {
        guard let editor else { return }
        let outcome = await editor.revertToPreviousVersion(item)
        guard outcome.replaced else {
            notices.append(Notice("Nothing was restored.", detail: outcome.message))
            return
        }
        notices.append(Notice("The previous version was restored."))
        await reload()
        await refreshAlbums()
        await refreshPlaces()
    }

    // MARK: - Collage

    public func createCollage(_ ids: [MediaID]) async {
        guard let editor else { return }
        let chosen = items.filter { ids.contains($0.id) && $0.kind == .image }
        guard chosen.count >= 2 else {
            notices.append(Notice("Choose at least two photos to make a collage."))
            return
        }
        var members: [MediaID: EditSource] = [:]
        var sizes: [MediaID: Int] = [:]
        for item in chosen {
            guard let source = await editor.source(for: item) else { continue }
            members[item.id] = source
            if let pixelSize = item.pixelSize { sizes[item.id] = Int(pixelSize.longSide) }
        }
        let ordered = chosen.compactMap { members[$0.id] == nil ? nil : $0.id }
        guard ordered.count >= 2 else {
            notices.append(Notice("The selected photos could not be found."))
            return
        }
        editingSession?.cancel()
        editingSession = nil
        let session = CollageSession(
            document: CollageDocument(memberIDs: ordered),
            members: members,
            sourceLongSides: sizes,
            service: editor
        )
        collageSession = session
        await session.renderPreview()
    }

    public func closeCollage() {
        collageSession?.cancel()
        collageSession = nil
    }

    public func exportCollage(to url: URL) async {
        guard let editor, let session = collageSession else { return }
        let written = await editor.writeCollage(
            session.document,
            members: session.members,
            sourceLongSides: session.sourceLongSides,
            to: url
        )
        notices.append(written
            ? Notice("Exported “\(url.lastPathComponent)”.", detail: url.deletingLastPathComponent().path)
            : Notice("The collage could not be exported.",
                     detail: "Choose a folder Gallery can write to."))
    }

    /// A batch copy of the selection, at the destination and with the naming policy the panel returned.
    public private(set) var exportProgress: Exporter.Progress?
    public var isExporting: Bool { exportProgress != nil }

    public func exportCopies(
        _ ids: [MediaID], to folder: URL, policy: ExportNaming.Policy
    ) async {
        guard let editor else { return }
        let chosen = items.filter { ids.contains($0.id) && $0.kind == .image }
        guard !chosen.isEmpty else {
            notices.append(Notice("There are no photos in this selection to export."))
            return
        }
        var requests: [ExportRequest] = []
        for item in chosen {
            guard let source = await editor.source(for: item) else { continue }
            var recipe = EditRecipe()
            recipe.format = OutputFormat(kind: OutputFormats.kind(for: source.url) ?? .jpeg)
            requests.append(ExportRequest(source: source, recipe: recipe))
        }
        guard !requests.isEmpty else {
            notices.append(Notice("The selected files could not be found."))
            return
        }
        exportProgress = Exporter.Progress(completed: 0, total: requests.count)
        let outcome = await editor.exportCopies(requests, to: folder, policy: policy) { [weak self] progress in
            Task { @MainActor in self?.exportProgress = progress }
        }
        exportProgress = nil
        var detail = folder.path
        if !outcome.failed.isEmpty {
            detail += " — " + (outcome.failed.values.first?.userMessage ?? "")
        }
        if !outcome.skipped.isEmpty {
            detail += " — \(outcome.skipped.count) skipped because a file with that name exists."
        }
        notices.append(Notice(
            outcome.written.count == 1
                ? "Exported one copy."
                : "Exported \(outcome.written.count) copies.",
            detail: detail
        ))
    }

    public func cancelExport() async {
        await editor?.cancelExport()
    }

    /// The editor's one write action so far: a copy, at a destination the user chose in a panel.
    public func exportEditorCopy(to destination: URL) async {
        guard let editor, let session = editingSession else { return }
        let request = ExportRequest(source: session.source, recipe: session.recipe)
        switch await editor.exportCopy(request, to: destination) {
        case .success(let url):
            notices.append(Notice(
                "Exported “\(url.lastPathComponent)”.",
                detail: url.deletingLastPathComponent().path
            ))
        case .failure(let error):
            notices.append(Notice("The copy could not be exported.", detail: error.userMessage))
        }
    }

    public func toggleFavorite(_ id: MediaID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wanted = !items[index].isFavorite
        do {
            try await catalog.setFavorite(id, wanted)
            items[index].isFavorite = wanted
        } catch {
            notices.append(Notice("Could not change the favorite.", detail: "\(error)"))
        }
    }

    /// The toolbar's star when more than one row is selected: all favorite, or all unfavorite.
    public func toggleFavoriteSelection() async {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let wanted = !chosen.allSatisfy(\.isFavorite)
        do {
            try await catalog.setFavorites(chosen.map(\.id), wanted)
            for index in items.indices where selectedIDs.contains(items[index].id) {
                items[index].isFavorite = wanted
            }
        } catch {
            notices.append(Notice("Could not change the favorites.", detail: "\(error)"))
        }
    }

    // MARK: - Trash

    public var isRecentlyDeleted: Bool { selection == .recentlyDeleted }

    /// ⌘⌫. The file leaves the folder and the row leaves every album; both come back together if the move
    /// fails, because a row flagged deleted over a file that never moved is the one lie this can't tell.
    public func moveToTrash(_ ids: [MediaID]) async {
        let selected = items.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let outcome = await trash.trash(selected)
        report(outcome.failed, what: "delete")
        if let viewerID, ids.contains(viewerID) { closeViewer() }
        await reload()
        await refreshAlbums()
    }

    public func restore(_ ids: [MediaID]) async {
        let selected = items.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let outcome = await trash.restore(selected)
        report(outcome.failed, what: "restore")
        if let viewerID, ids.contains(viewerID) { closeViewer() }
        await reload()
        await refreshAlbums()
    }

    /// Empty out of the trash for good. The row stays in the catalog as `purged`, so the ledger still knows
    /// where the file went after it stopped existing.
    public func deleteForever(_ ids: [MediaID]) async {
        let selected = items.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        let outcome = await trash.purge(selected)
        report(outcome.failed, what: "delete forever")
        if let viewerID, ids.contains(viewerID) { closeViewer() }
        await reload()
        await refreshAlbums()
    }

    /// The monthly sweep behind "Recently Deleted", run at launch. Silent: there is nothing to tell the user
    /// about a file they asked to delete a month ago.
    private func purgeExpiredTrash() async {
        let cutoff = Date().addingTimeInterval(-Self.trashRetention)
        let outcome = await trash.purgeExpired(olderThan: cutoff)
        guard !outcome.purged.isEmpty else { return }
        await refreshAlbums()
        await reload()
    }

    private func report(_ failures: [MediaID: String], what: String) {
        guard !failures.isEmpty else { return }
        let detail = failures.values.sorted().first
        let count = failures.count
        notices.append(Notice(count == 1 ? "One item could not \(what)."
                                         : "\(count) items could not \(what).",
                              detail: detail))
    }

    // MARK: - Notices

    public func dismissNotice() {
        guard !notices.isEmpty else { return }
        notices.removeFirst()
    }

    // MARK: - Derived view state

    /// The header over the grid. A search is titled by what was searched for, because "All Media" over two
    /// matching photos is a claim about the library that the page is not showing.
    public var selectionTitle: String {
        if isSearching { return "Search “\(appliedSearch)”" }
        switch selection {
        case .day(let bucket): return days.first { $0.kind == .day(bucket) }?.title ?? "Day"
        case .month(let bucket): return months.first { $0.kind == .month(bucket) }?.title ?? "Month"
        case .location(let id): return places.first { $0.kind == .location(id) }?.title ?? "Place"
        case .tag(let key): return TagVocabulary.title(for: key.slug)
        case .person(let key):
            return people.first { $0.kind == .person(key) }?.title ?? "Person"
        case .subfolder(let sourceID, let path):
            if let match = subfolders[sourceID]?.first(where: {
                $0.kind == .subfolder(sourceID, relativePath: path)
            }) { return match.title }
            return path.split(separator: "/").last.map(String.init) ?? path
        default: return selection.uiTitle(sources: sources)
        }
    }

    // MARK: - Day sections

    /// One header per capture day, in the order the page is sorted. Only for the date sort: under "Name" a
    /// day header would be a claim about an ordering that is not being shown.
    public struct DaySection: Identifiable, Sendable, Hashable {
        public var id: Int32 { bucket }
        public let bucket: Int32
        public let title: String
        public let items: [MediaItem]
    }

    public var daySections: [DaySection] {
        guard sort.field == .captureDate, !items.isEmpty else { return [] }
        var order: [Int32] = []
        var grouped: [Int32: [MediaItem]] = [:]
        for item in items {
            let bucket = item.dayBucket
            if grouped[bucket] == nil { order.append(bucket) }
            grouped[bucket, default: []].append(item)
        }
        return order.map { DaySection(bucket: $0, title: Self.title(forDay: $0), items: grouped[$0] ?? []) }
    }

    static func title(forDay bucket: Int32) -> String {
        guard bucket > 20_000_000 else { return "Undated" }
        var components = DateComponents()
        components.year = Int(bucket) / 10_000
        components.month = (Int(bucket) / 100) % 100
        components.day = Int(bucket) % 100
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return "Undated" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// The folder a selection belongs to, for the header and the HUD.
    public var sourceForSelection: FolderSource? {
        let id: SourceID? = switch selection {
        case .folder(let sourceID): sourceID
        case .subfolder(let sourceID, _): sourceID
        default: nil
        }
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }

    /// Progress worth drawing: a scan that is not finished, for the folder being looked at or for any
    /// folder at all when the selection is a cross-library album.
    ///
    /// The two passes are merged rather than chosen between: while a walk is counting, its numbers are the
    /// story ("4,000 files so far"), and once it is not, the drain's are ("400 of them have a poster yet").
    /// Showing the walk's finished frame instead would call a folder ready while the grid is still blank.
    public var activeProgress: IndexProgress? {
        let sourceID = sourceForSelection?.id
        func matches(_ progress: IndexProgress) -> Bool {
            sourceID == nil || progress.sourceID == sourceID
        }
        var live = previews.values.filter(matches)
        live.append(contentsOf: progress.values.filter { $0.phase.isCounting && matches($0) })
        live.append(contentsOf: analysisProgress.values.filter { $0.phase == .analyzing && matches($0) })
        return live.max { lhs, rhs in
            // A library being read is not "up to date": an active analysis frame outranks a finished drain,
            // which would otherwise win on phase order and hide the work that is actually happening.
            if lhs.phase == .analyzing, rhs.phase == .finished { return false }
            if lhs.phase == .finished, rhs.phase == .analyzing { return true }
            if lhs.phase == rhs.phase { return lhs.discovered < rhs.discovered }
            return lhs.phase.order < rhs.phase.order
        }
    }

    /// The HUD's pause means one of two things: stop this folder's walk, or hold the library-wide analysis,
    /// which has no single folder to name.
    public func canPauseScan(_ progress: IndexProgress) -> Bool {
        if progress.phase == .analyzing { return true }
        return canControlScan(progress)
    }

    public func pauseScan(_ progress: IndexProgress) async {
        if progress.phase == .analyzing {
            await setAnalysisPaused(!progress.isPaused)
        } else {
            await setPaused(progress.sourceID, !progress.isPaused)
        }
    }

    /// Whether the HUD's pause and cancel mean what they say for this number. They belong to a folder's walk;
    /// once that walk has ended, what is left on screen is the library-wide preview queue, which has no
    /// single folder to stop.
    public func canControlScan(_ progress: IndexProgress) -> Bool {
        self.progress[progress.sourceID]?.phase.isCounting == true
    }
}

extension IndexPhase {
    /// Coarse ordering for "which of these two scans is further along" — the enum is a pipeline, not a set.
    var order: Int {
        switch self {
        case .resolving: 0
        case .enumerating: 1
        case .sweeping: 2
        case .readingMetadata: 3
        case .deriving: 4
        case .thumbnailing: 5
        case .analyzing: 6
        case .watching: 7
        case .finished: 8
        case .failed: -1
        }
    }
}
