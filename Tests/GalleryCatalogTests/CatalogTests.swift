import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain
import GallerySQLite

@Suite("Catalog write path")
struct CatalogTests {
    @Test("A fresh database is current, empty and internally consistent")
    func freshDatabase() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }

        try await fixture.addSource()
        #expect(!(try await fixture.reader.isStaleSchema))
        #expect(try await fixture.catalog.integrityCheck() == ["ok"])
        #expect(try await fixture.reader.count(album: .all) == 0)
        #expect(try await fixture.catalog.stageCounts().isEmpty)
    }

    @Test("Reopening the same file neither migrates nor duplicates rows")
    func reopenKeepsRows() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id)])
        #expect(ids.count == 1)

        let second = try await fixture.reopened()
        #expect(try await second.sources().count == 1)
        #expect(try await fixture.reader.count(album: .all) == 1)
        #expect(try await fixture.reader.item(id: ids[0]) != nil)
    }

    @Test("Picking the same folder again re-grants access and keeps the catalog")
    func repickRefreshesState() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let first = try await fixture.addSource("Pictures", state: .accessDenied)
        try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: first.id)])

        let repicked = try await fixture.catalog.addSource(
            displayName: "Pictures", rootPath: "/Volumes/Pictures", volumeID: "vol-1", state: .ok
        )
        #expect(repicked.id == first.id)
        #expect(repicked.bookmarkState == .ok)
        #expect(try await fixture.reader.count(album: .all) == 1)
        #expect(try await fixture.catalog.sources().count == 1)
    }

    @Test("A batch that fails partway leaves nothing behind")
    func batchRollsBack() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()

        // The second row references a source that does not exist, so the foreign key aborts the upsert —
        // and the first, valid row must be rolled back with it rather than half-committed.
        let orphan = makeItem("IMG_2.JPG", documentID: 2, sourceID: SourceID(rawValue: 9999))
        var failure: (any Error)?
        do {
            try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id), orphan])
        } catch {
            failure = error
        }
        #expect(failure != nil)
        #expect(try await fixture.reader.count(album: .all) == 0)
        #expect(try await fixture.catalog.stageCounts().isEmpty)
    }

    @Test("A rename keeps the row, the favorite and the thumbnail identity")
    func renameKeepsIdentity() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let original = makeItem("IMG_100.JPG", documentID: 100, sourceID: source.id)
        let ids = try await fixture.record([original])
        try await fixture.catalog.setFavorite(ids[0], true)

        let renamed = MediaItem(
            id: ids[0], identity: original.identity, sourceID: source.id,
            relativePath: "Holiday/IMG_9999.JPG", parentDirectory: "Holiday",
            name: "IMG_9999.JPG", fileExtension: "JPG", kind: .image,
            uniformTypeIdentifier: "public.jpeg"
        )
        let afterRename = try await fixture.record([renamed])
        #expect(afterRename == ids)

        let stored = try #require(try await fixture.reader.item(id: ids[0]))
        #expect(stored.relativePath == "Holiday/IMG_9999.JPG")
        #expect(stored.isFavorite, "a favorite that does not survive a rename is a favorite the user lost")
        #expect(try await fixture.reader.count(album: .all) == 1)
        #expect(try await fixture.reader.count(album: .favorites) == 1)
        #expect(try await fixture.reader.count(album: .subfolder(source.id, relativePath: "Holiday")) == 1)
    }

    @Test("The row that still claims a moved-to path retires")
    func stalePathOwnerRetires() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let mover = makeItem("a.JPG", documentID: 1, sourceID: source.id)
        let occupant = makeItem("b.JPG", documentID: 2, sourceID: source.id)
        let ids = try await fixture.record([mover, occupant])

        // `a.JPG` is renamed onto `b.JPG`, whose own row is a stale entry for a file that is gone.
        let renamed = MediaItem(
            id: ids[0], identity: mover.identity, sourceID: source.id,
            relativePath: "b.JPG", parentDirectory: "", name: "b.JPG", fileExtension: "JPG",
            kind: .image, uniformTypeIdentifier: "public.jpeg"
        )
        let result = try await fixture.record([renamed])
        #expect(result == [ids[0]])
        #expect(try await fixture.reader.item(id: ids[1]) == nil)
        #expect(try await fixture.reader.count(album: .all) == 1)
    }

    @Test("A file replaced outside the app takes over its path instead of failing the batch")
    func replacedFileTakesOverItsPath() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let original = makeItem("IMG_1.JPG", resourceID: 4242, sourceID: source.id, size: 1024)
        _ = try await fixture.record([original])

        // The same path with a new inode: what an editor that saves by replacing the file leaves behind.
        // Until this was handled, the unique path index rejected the whole batch — every rescan, forever.
        let replaced = makeItem("IMG_1.JPG", resourceID: 7777, sourceID: source.id, size: 2048)
        let after = try await fixture.record([replaced])

        #expect(after.count == 1)
        #expect(try await fixture.reader.count(album: .all) == 1, "the stale row retired rather than blocking")
        let stored = try #require(try await fixture.reader.item(id: after[0]))
        #expect(stored.identity.resourceID == 7777)
        #expect(stored.byteSize == 2048)
    }

    @Test("A stat-only rescan cannot erase what pass B decoded")
    func passADoesNotClobberMetadata() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let enumerated = makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id, size: 4096)
        let ids = try await fixture.record([enumerated])

        let capture = try captured("2024-05-04")
        var decoded = enumerated
        decoded.id = ids[0]
        decoded.capture = capture
        decoded.pixelSize = PixelSize(width: 6000, height: 4000)
        decoded.stage = .thumbnailed
        try await fixture.metadata([decoded])

        // The same bytes walked again: nothing pass B knew has become untrue, so the stage it earned stands.
        try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id, size: 4096)])
        #expect(try await fixture.reader.item(id: ids[0])?.stage == .thumbnailed)

        // Pass A re-walks the folder and finds different bytes: the stage describes a file that is gone.
        try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id, size: 5000)])

        let stored = try #require(try await fixture.reader.item(id: ids[0]))
        #expect(stored.byteSize == 5000)
        #expect(stored.stage == .enumerated, "a changed file goes back through pass B")
        #expect(stored.pixelSize?.width == 6000, "and the knowledge is not erased on the way")
        #expect(stored.capture?.dayBucket == capture.dayBucket)

        // Which is the whole point: an edited photo is work again, so the queue has to take it back.
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)
        #expect(try await fixture.catalog.queuedWorkCount(sourceID: source.id) == 1)
    }

    @Test("A per-file error clears when the file changes, not when it is re-walked")
    func errorTracksFileChange() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let broken = makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id, error: .corrupt)
        let ids = try await fixture.record([broken])

        // The identical stat, now walked by a build that no longer thinks it is broken.
        try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id)])
        #expect(try await fixture.reader.item(id: ids[0])?.error == .corrupt)

        // A different file size is a changed file, so the stale error goes with it.
        try await fixture.record([makeItem("IMG_1.JPG", documentID: 1, sourceID: source.id, size: 8192)])
        #expect(try await fixture.reader.item(id: ids[0])?.error == IndexError.none)
    }

    @Test("Identity falls back to inode, then to path")
    func identityFallback() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()

        let withInode = makeItem("IMG_1.JPG", resourceID: 4242, sourceID: source.id)
        let withNeither = makeItem("IMG_2.JPG", sourceID: source.id)
        let ids = try await fixture.record([withInode, withNeither])

        // Same inode, renamed.
        let renamedInode = MediaItem(
            id: ids[0], identity: withInode.identity, sourceID: source.id,
            relativePath: "IMG_7.JPG", parentDirectory: "", name: "IMG_7.JPG", fileExtension: "JPG",
            kind: .image, uniformTypeIdentifier: "public.jpeg"
        )
        #expect(try await fixture.record([renamedInode]) == [ids[0]])

        // Path-keyed row: the path *is* the identity, so a new path is a new row.
        let renamedPath = MediaItem(
            id: ids[1], identity: withNeither.identity, sourceID: source.id,
            relativePath: "IMG_8.JPG", parentDirectory: "", name: "IMG_8.JPG", fileExtension: "JPG",
            kind: .image, uniformTypeIdentifier: "public.jpeg"
        )
        let fresh = try await fixture.record([renamedPath])
        #expect(fresh.first != ids[1])
        #expect(try await fixture.reader.count(album: .all) == 3)
    }

    @Test("Two sources on one volume do not share rows by document id")
    func documentIdentityIsScopedPerVolume() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let camera = try await fixture.addSource("SD", volume: "vol-1")
        let phone = try await fixture.addSource("Phone", volume: "vol-2")

        let ids = try await fixture.record([
            makeItem("IMG_1.JPG", documentID: 7, sourceID: camera.id, volumeID: "vol-1"),
            makeItem("IMG_1.JPG", documentID: 7, sourceID: phone.id, volumeID: "vol-2"),
        ])
        #expect(Set(ids).count == 2, "the same document id on two volumes is two files")
    }

    @Test("Dropping a source takes its media with it and leaves the rest alone")
    func removeSourceCascades() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let kept = try await fixture.addSource("Keep", volume: "vol-1")
        let dropped = try await fixture.addSource("Drop", volume: "vol-2")
        let ids = try await fixture.record([
            makeItem("a.JPG", documentID: 1, sourceID: kept.id, volumeID: "vol-1"),
            makeItem("b.JPG", documentID: 2, sourceID: dropped.id, volumeID: "vol-2"),
        ])
        try await fixture.catalog.setFavorite(ids[1], true)

        try await fixture.catalog.removeSource(id: dropped.id)
        #expect(try await fixture.catalog.sources().count == 1)
        #expect(try await fixture.reader.count(album: .all) == 1)
        #expect(try await fixture.reader.count(album: .favorites) == 0)
        #expect(try await fixture.reader.item(id: ids[0]) != nil)
    }

    @Test("Deleting rows by id leaves no orphan in the favorite or FTS tables")
    func deleteMediaCascades() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        var item = makeItem("kyoto-temple.JPG", documentID: 1, sourceID: source.id)
        let ids = try await fixture.record([item])
        item.id = ids[0]
        item.searchText = "temple at night in kyoto"
        try await fixture.metadata([item])
        try await fixture.catalog.setFavorite(ids[0], true)

        try await fixture.catalog.deleteMedia(ids: ids)
        #expect(try await fixture.catalog.integrityCheck() == ["ok"])
        #expect(try await fixture.reader.count(album: .favorites) == 0)
        #expect(try await fixture.reader.search("kyoto").isEmpty)
    }

    // MARK: - Work queue

    @Test("The queue holds exactly the unfinished rows, and re-enqueueing does not duplicate them")
    func queueIsIdempotent() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([
            makeItem("a.JPG", documentID: 1, sourceID: source.id),
            makeItem("b.JPG", documentID: 2, sourceID: source.id),
            makeItem("c.JPG", documentID: 3, sourceID: source.id, stage: .thumbnailed),
        ])

        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)
        #expect(try await fixture.catalog.queuedWorkCount(sourceID: source.id) == 2)

        let claimed = try await fixture.catalog.claimWork(limit: 1)
        #expect(claimed.count == 1)
        #expect(claimed[0].attempts == 1)
        try await fixture.catalog.completeWork(ids: claimed.map(\.queueID))
        #expect(try await fixture.catalog.queuedWorkCount() == 1)
    }

    @Test("Viewport-priority work raises a queued item instead of queueing it twice")
    func queueOrdersByPriority() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id),
                                  makeItem("b.JPG", documentID: 2, sourceID: source.id)])
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id, priority: 10)
        #expect(try await fixture.catalog.queuedWorkCount() == 2)

        let claimed = try await fixture.catalog.claimWork(limit: 2)
        #expect(claimed.map(\.priority) == [10, 10])
    }

    @Test("Within one tier the queue serves the newest file first, and an undated one last")
    func queueOrdersByRecency() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        var old = makeItem("old.JPG", documentID: 1, sourceID: source.id)
        old.modificationDate = Date(timeIntervalSince1970: 1_000_000)
        var recent = makeItem("recent.JPG", documentID: 2, sourceID: source.id)
        recent.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let undated = makeItem("undated.JPG", documentID: 3, sourceID: source.id)
        let ids = try await fixture.record([old, recent, undated])
        let names = Dictionary(uniqueKeysWithValues: zip(ids.map(\.rawValue), ["old", "recent", "undated"]))

        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)
        let claimed = try await fixture.catalog.claimWork(limit: 3)
        var order: [String] = []
        for item in claimed {
            let id = try #require(item.mediaID)
            order.append(try #require(names[id.rawValue]))
        }
        // Pass B is allowed to spend an hour on a 100k library; what it may not do is spend the first hour
        // on whatever the walk happened to reach first.
        #expect(order == ["recent", "old", "undated"])
    }

    @Test("Raising the viewport reorders the queue without queueing anything twice")
    func raiseJumpsTheQueue() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([
            makeItem("a.JPG", documentID: 1, sourceID: source.id),
            makeItem("b.JPG", documentID: 2, sourceID: source.id),
        ])
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)

        try await fixture.catalog.raiseWorkPriority(mediaIDs: [ids[1]], priority: 5)
        #expect(try await fixture.catalog.queuedWorkCount() == 2, "a raise is not a second entry")
        let first = try #require(await fixture.catalog.claimWork(limit: 1).first)
        #expect(first.mediaID == ids[1])
        #expect(first.priority == 5)

        // A row pass B already finished has nothing left to raise, so the viewport call cannot resurrect it.
        let finished = try #require(await fixture.reader.item(id: ids[0]))
        try await fixture.catalog.recordMetadata([finished.decoded(stage: .thumbnailed)])
        try await fixture.catalog.raiseWorkPriority(mediaIDs: [ids[0]], priority: 9)
        // `b` is still queued, and the claim above only counts an attempt — it does not take the row out.
        #expect(try await fixture.catalog.queuedWorkCount() == 2)
    }

    @Test("A v1 library walks forward to v2 with its queue intact")
    func v1QueueGainsRank() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id)])
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)

        // Put the database back exactly as the first release left it: the column did not exist, and the
        // claim index could not order by it. A second connection is what a relaunch is.
        let downgraded = try SQLiteHandle.open(path: fixture.databaseURL.path, kind: .readWrite)
        try downgraded.write {
            try downgraded.downgradeToV1()
            try downgraded.setUserVersion(1)
        }

        let reopened = try await fixture.reopened()
        let claimed = try await reopened.claimWork(limit: 1)
        #expect(claimed.count == 1, "the queue survived the step")
        try await reopened.enqueuePendingWork(sourceID: source.id)
        #expect(try await reopened.queuedWorkCount() == 1, "rank backfills into the row that was already queued")
    }

    @Test("A failing item is recorded and stays queued for the next pass")
    func failedWorkRemainsQueued() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id)])
        try await fixture.catalog.enqueuePendingWork(sourceID: source.id)

        let claimed = try await fixture.catalog.claimWork(limit: 1)
        try await fixture.catalog.failWork(id: claimed[0].queueID, error: "ImageIO returned nil")
        #expect(try await fixture.catalog.queuedWorkCount() == 1)
        #expect(try await fixture.catalog.claimWork(limit: 1)[0].attempts == 2)
    }

    // MARK: - Trash

    @Test("A trashed row leaves every album and appears in Recently Deleted")
    func trashHidesAndLists() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id)])
        let ledgerID = try await fixture.catalog.beginTrash(TrashLedgerEntry(
            mediaID: ids[0], sourceID: source.id, fromRelativePath: "a.JPG",
            fromVolumeID: "vol-1", mode: .appTrash, byteSize: 1024
        ))

        #expect(try await fixture.reader.count(album: .all) == 0)
        #expect(try await fixture.reader.count(album: .recentlyDeleted) == 1)
        #expect(try await fixture.reader.item(id: ids[0])?.trash == .trashed)

        try await fixture.catalog.finishTrash(ledgerID: ledgerID, mediaID: ids[0], succeeded: true, error: nil)
        #expect(try await fixture.reader.count(album: .recentlyDeleted) == 1)
    }

    @Test("A failed system-trash puts the row back where the file still is")
    func failedTrashRestoresVisibility() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id)])
        let ledgerID = try await fixture.catalog.beginTrash(TrashLedgerEntry(
            mediaID: ids[0], sourceID: source.id, fromRelativePath: "a.JPG",
            fromVolumeID: "vol-1", mode: .systemTrash
        ))
        try await fixture.catalog.finishTrash(
            ledgerID: ledgerID, mediaID: ids[0], succeeded: false,
            error: "This volume cannot be trashed."
        )

        #expect(try await fixture.reader.count(album: .all) == 1)
        #expect(try await fixture.reader.count(album: .recentlyDeleted) == 0)
        #expect(try await fixture.reader.item(id: ids[0])?.trash == .live)
    }

    @Test("Restoring moves the row back into the albums; a failed restore leaves it trashed")
    func restoreLadder() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id)])
        let ledgerID = try await fixture.catalog.beginTrash(TrashLedgerEntry(
            mediaID: ids[0], sourceID: source.id, fromRelativePath: "a.JPG",
            fromVolumeID: "vol-1", mode: .appTrash
        ))

        try await fixture.catalog.restoreFromLedger(
            ledgerID: ledgerID, mediaID: ids[0], succeeded: false, error: "Path is occupied."
        )
        #expect(try await fixture.reader.count(album: .recentlyDeleted) == 1)

        try await fixture.catalog.restoreFromLedger(
            ledgerID: ledgerID, mediaID: ids[0], succeeded: true, error: nil
        )
        #expect(try await fixture.reader.count(album: .all) == 1)
        #expect(try await fixture.reader.count(album: .recentlyDeleted) == 0)
    }

    @Test("Purge empties Recently Deleted and only picks up what is old enough")
    func purgeSelectsByAge() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([makeItem("a.JPG", documentID: 1, sourceID: source.id)])
        let old = try await fixture.catalog.beginTrash(TrashLedgerEntry(
            mediaID: ids[0], sourceID: source.id, fromRelativePath: "a.JPG",
            fromVolumeID: "vol-1", mode: .appTrash,
            trashedAt: Date(timeIntervalSinceNow: -31 * 86_400)
        ))

        let due = try await fixture.catalog.purgeOlderThan(Date(timeIntervalSinceNow: -30 * 86_400))
        #expect(due.map(\.id) == [old])
        #expect(try await fixture.catalog.purgeOlderThan(Date(timeIntervalSinceNow: -40 * 86_400)).isEmpty)

        try await fixture.catalog.recordPurge(ledgerID: old, mediaID: ids[0])
        #expect(try await fixture.reader.count(album: .recentlyDeleted) == 0)
        #expect(try await fixture.reader.count(album: .all) == 0)
    }

    // MARK: - Settings

    @Test("Settings overwrite in place")
    func settingsRoundTrip() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        try await fixture.catalog.setSetting("event.gapHours", "12")
        #expect(try await fixture.catalog.setting("event.gapHours") == "12")
        try await fixture.catalog.setSetting("event.gapHours", "18")
        #expect(try await fixture.catalog.setting("event.gapHours") == "18")
        #expect(try await fixture.catalog.setting("does.not.exist") == nil)
    }
}
