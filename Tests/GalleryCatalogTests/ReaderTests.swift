import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain
import GallerySQLite

/// A copy with pass-B fields filled in — the shape the metadata reader hands back, and the only way a test
/// can put a row into `stage = 3` without a decoder.
private func decoded(
    _ item: MediaItem,
    id: MediaID,
    capture: CaptureMoment? = nil,
    gps: GPSPoint? = nil,
    search: String? = nil,
    stage: IndexStage = .thumbnailed
) -> MediaItem {
    var copy = item
    copy.id = id
    copy.capture = capture ?? item.capture
    copy.gps = gps ?? item.gps
    copy.searchText = search ?? item.searchText
    copy.pixelSize = item.pixelSize ?? PixelSize(width: 4000, height: 3000)
    copy.stage = stage
    return copy
}

@Suite("Catalog read path")
struct ReaderTests {
    /// Five photos, one on each of five consecutive days, so a newest-first page walk has a total order.
    @discardableResult
    private func library(_ fixture: CatalogFixture, source: FolderSource) async throws -> [MediaID] {
        let days = ["2024-06-01", "2024-06-02", "2024-06-03", "2024-06-04", "2024-06-05"]
        let items = days.enumerated().map { index, _ in
            makeItem("IMG_\(index).JPG", documentID: Int64(index), sourceID: source.id)
        }
        let ids = try await fixture.record(items)
        try await fixture.metadata(zip(zip(items, ids), days).map { pair, day in
            decoded(pair.0, id: pair.1, capture: try captured(day), search: "photo number \(pair.0.name)")
        })
        return ids
    }

    @Test("Pages walk the whole album exactly once")
    func keysetPaging() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await library(fixture, source: source)

        var seen: [String] = []
        var cursor: SortCursor?
        var pages = 0
        while pages < 10 {
            let page = try await fixture.reader.page(album: .all, after: cursor, limit: 2)
            seen.append(contentsOf: page.items.map(\.name))
            pages += 1
            guard page.hasMore, let next = page.nextCursor else { break }
            cursor = next
        }

        #expect(seen == ["IMG_4.JPG", "IMG_3.JPG", "IMG_2.JPG", "IMG_1.JPG", "IMG_0.JPG"])
        #expect(pages == 3)
    }

    @Test("A burst of identical timestamps still pages without repeats, because id breaks the tie")
    func sameInstantPaging() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let capture = try captured("2024-06-05")
        let items = (0..<5).map {
            makeItem("IMG_\($0).JPG", documentID: Int64($0), sourceID: source.id)
        }
        let ids = try await fixture.record(items)
        try await fixture.metadata(zip(items, ids).map { decoded($0, id: $1, capture: capture) })

        var names: [String] = []
        var cursor: SortCursor?
        for _ in 0..<5 {
            let page = try await fixture.reader.page(album: .all, after: cursor, limit: 2)
            names.append(contentsOf: page.items.map(\.name))
            cursor = page.nextCursor
            if !page.hasMore { break }
        }
        #expect(Set(names).count == 5)
        #expect(names.count == 5)
    }

    @Test("An undated row sorts to the end of a newest-first grid")
    func undatedSortsLast() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await library(fixture, source: source)
        let noDate = makeItem("SCAN_1.JPG", documentID: 100, sourceID: source.id)
        let ids = try await fixture.record([noDate])
        try await fixture.metadata([decoded(noDate, id: ids[0], capture: nil)])

        let page = try await fixture.reader.page(album: .all, limit: 10)
        #expect(page.items.last?.name == "SCAN_1.JPG")
        #expect(page.items.count == 6)
        #expect(!page.hasMore)
    }

    @Test("A text sort carries a text cursor")
    func fileNameSortCursor() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([
            makeItem("alpha.JPG", documentID: 1, sourceID: source.id),
            makeItem("Beta.JPG", documentID: 2, sourceID: source.id),
            makeItem("gamma.JPG", documentID: 3, sourceID: source.id),
        ])

        let sort = MediaSort(field: .fileName, order: .ascending)
        let first = try await fixture.reader.page(album: .all, sort: sort, limit: 2)
        #expect(first.items.map(\.name) == ["alpha.JPG", "Beta.JPG"], "NOCASE makes Beta second, not first")
        #expect(first.nextCursor?.primary == .text("Beta.JPG"))

        let second = try await fixture.reader.page(album: .all, sort: sort, after: first.nextCursor, limit: 2)
        #expect(second.items.map(\.name) == ["gamma.JPG"])
        #expect(!second.hasMore)
    }

    @Test("Counts and pages agree, because they are the same predicate")
    func countMatchesPage() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await library(fixture, source: source)

        let count = try await fixture.reader.count(album: .month(202406))
        let page = try await fixture.reader.page(album: .month(202406), limit: 50)
        #expect(count == page.items.count)
        #expect(count == 5)
    }

    @Test("Type albums keep the Live Photo pair down to one entry")
    func videoAlbumExcludesLiveCompanion() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([
            makeItem("IMG_1.MOV", documentID: 1, sourceID: source.id, kind: .video,
                     subtype: .livePhotoCompanion),
            makeItem("IMG_2.MOV", documentID: 2, sourceID: source.id, kind: .video),
            makeItem("IMG_3.JPG", documentID: 3, sourceID: source.id),
        ])

        #expect(try await fixture.reader.count(album: .allVideos) == 1)
        #expect(try await fixture.reader.count(album: .allPhotos) == 1)
        #expect(try await fixture.reader.count(album: .all) == 3)
    }

    @Test("Screenshots, offline, problems and uncategorized each read their own flag")
    func smartFlags() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([
            makeItem("Screenshot 2024-06-01 at 10.11.JPG", documentID: 1, sourceID: source.id,
                     subtype: .screenshot),
            makeItem("offline.JPG", documentID: 2, sourceID: source.id, isOffline: true),
            makeItem("broken.JPG", documentID: 3, sourceID: source.id, error: .corrupt),
            makeItem("normal.JPG", documentID: 4, sourceID: source.id),
        ])

        #expect(try await fixture.reader.count(album: .screenshots) == 1)
        #expect(try await fixture.reader.count(album: .offline) == 1)
        #expect(try await fixture.reader.count(album: .problems) == 1)
        #expect(try await fixture.reader.count(album: .uncategorized) == 4)
        #expect(try await fixture.reader.count(album: .raw) == 0)
    }

    @Test("A day with GPS and no capture date is categorized, just not by date")
    func categorizedMeansDateOrPlace() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("track.JPG", documentID: 1, sourceID: source.id)
        let ids = try await fixture.record([item])
        try await fixture.metadata([decoded(item, id: ids[0], gps: GPSPoint(latitude: 35.68, longitude: 139.69))])

        #expect(try await fixture.reader.count(album: .uncategorized) == 0)
        let stored = try #require(try await fixture.reader.item(id: ids[0]))
        #expect(stored.gps?.isValid == true)
    }

    @Test("Folder albums nest under their source and pick a decoded cover")
    func folderAlbums() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let items = [
            makeItem("root.JPG", documentID: 1, sourceID: source.id),
            makeItem("a.JPG", at: "Holiday/a.JPG", documentID: 2, sourceID: source.id),
            makeItem("b.JPG", at: "Holiday/b.JPG", documentID: 3, sourceID: source.id),
            makeItem("c.JPG", at: "Work/c.JPG", documentID: 4, sourceID: source.id),
        ]
        let ids = try await fixture.record(items)
        // Only `Holiday/b.JPG` has been through pass B, so it is the only legal cover in that folder.
        try await fixture.metadata([decoded(items[2], id: ids[2], capture: try captured("2024-06-02"))])

        let albums = try await fixture.reader.albums(of: .folder(source.id))
        let byTitle = Dictionary(uniqueKeysWithValues: albums.map { ($0.title, $0) })
        #expect(Set(byTitle.keys) == ["Holiday", "Work"])
        #expect(byTitle["Holiday"]?.itemCount == 2)
        #expect(byTitle["Holiday"]?.coverMediaID == ids[2])
        #expect(byTitle["Work"]?.coverMediaID == nil, "an undecoded folder has no cover rather than a blank tile")
    }

    @Test("Date albums drop days too small to be an album; months roll everything up")
    func dateAlbums() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let days = ["2024-06-05", "2024-06-05", "2024-06-05", "2023-01-01"]
        let items = days.enumerated().map { index, _ in
            makeItem("IMG_\(index).JPG", documentID: Int64(index), sourceID: source.id)
        }
        let ids = try await fixture.record(items)
        try await fixture.metadata(zip(zip(items, ids), days).map { pair, day in
            decoded(pair.0, id: pair.1, capture: try captured(day))
        })

        let daysAlbums = try await fixture.reader.dateAlbums(minimumItems: 3)
        #expect(daysAlbums.map(\.kind) == [.day(20240605)])
        #expect(daysAlbums.first?.itemCount == 3)

        let months = try await fixture.reader.monthAlbums()
        #expect(months.map(\.title) == ["June 2024", "January 2023"])
        #expect(months.map(\.itemCount) == [3, 1])
        #expect(try await fixture.reader.dateAlbums(minimumItems: 2).isEmpty == false)
    }

    @Test("Search ranks a name match above a body match and brackets the hit")
    func searchRanksAndSnippets() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let named = makeItem("kyoto-street.JPG", documentID: 1, sourceID: source.id)
        let described = makeItem("IMG_2.JPG", documentID: 2, sourceID: source.id)
        let ids = try await fixture.record([named, described])

        try await fixture.metadata([
            decoded(named, id: ids[0], search: "taken in the evening"),
            decoded(described, id: ids[1], search: "a temple in kyoto with lanterns"),
        ])

        let hits = try await fixture.reader.search("kyoto")
        #expect(hits.map(\.item.name) == ["kyoto-street.JPG", "IMG_2.JPG"])
        #expect(hits[0].rank < hits[1].rank, "bm25 is more negative for a better match")
        #expect(hits[0].snippet.contains("[kyoto]"), "the filename is the hit, so the filename is the snippet")
        #expect(hits[1].snippet.contains("[kyoto]"))
    }

    @Test("Search stays inside the album it was given")
    func searchWithinAlbum() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let camera = try await fixture.addSource("Camera", volume: "vol-1")
        let phone = try await fixture.addSource("Phone", volume: "vol-2")
        let inCamera = makeItem("kyoto.JPG", documentID: 1, sourceID: camera.id, volumeID: "vol-1")
        let inPhone = makeItem("kyoto.JPG", documentID: 2, sourceID: phone.id, volumeID: "vol-2")
        let ids = try await fixture.record([inCamera, inPhone])
        try await fixture.metadata([decoded(inCamera, id: ids[0]), decoded(inPhone, id: ids[1])])

        #expect(try await fixture.reader.search("kyoto").count == 2)
        let scoped = try await fixture.reader.search("kyoto", within: .folder(camera.id))
        #expect(scoped.map(\.item.sourceID) == [camera.id])
    }

    @Test("A trashed row leaves the search index as it leaves the albums")
    func searchSkipsTrashed() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("kyoto.JPG", documentID: 1, sourceID: source.id)
        let ids = try await fixture.record([item])
        try await fixture.metadata([decoded(item, id: ids[0])])
        #expect(try await fixture.reader.search("kyoto").count == 1)

        _ = try await fixture.catalog.beginTrash(TrashLedgerEntry(
            mediaID: ids[0], sourceID: source.id, fromRelativePath: "kyoto.JPG",
            fromVolumeID: "vol-1", mode: .appTrash
        ))
        #expect(try await fixture.reader.search("kyoto").isEmpty)
    }

    @Test("Non-ASCII and operator-looking text search without throwing")
    func searchIsNotFooledBySyntax() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("京都.JPG", documentID: 1, sourceID: source.id)
        let ids = try await fixture.record([item])
        try await fixture.metadata([decoded(item, id: ids[0], search: "AND OR NOT NEAR {}")])

        #expect(try await fixture.reader.search("京都").count == 1)
        #expect(try await fixture.reader.search("sunrise & clouds").isEmpty)
        #expect(try await fixture.reader.search("Tokyo!'").isEmpty)
        #expect(try await fixture.reader.search("NEAR (a, b)").isEmpty)
        #expect(try await fixture.reader.search("   ").isEmpty)
    }

    @Test("Prefix search matches a stem")
    func searchPrefix() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("sunset-beach.JPG", documentID: 1, sourceID: source.id)
        let ids = try await fixture.record([item])
        try await fixture.metadata([decoded(item, id: ids[0])])

        #expect(try await fixture.reader.search("sunset").count == 1)
        #expect(try await fixture.reader.search("sun").isEmpty)
        #expect(try await fixture.reader.search("sun", prefix: true).count == 1)
    }

    @Test("Rebuilding FTS restores the index from the table")
    func rebuildFTSFromTable() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let item = makeItem("marina.JPG", documentID: 1, sourceID: source.id)
        let ids = try await fixture.record([item])
        try await fixture.metadata([decoded(item, id: ids[0], search: "harbour lights")])

        try await fixture.catalog.rebuildFTS()
        #expect(try await fixture.reader.search("harbour").count == 1)
        #expect(try await fixture.catalog.integrityCheck() == ["ok"])
    }

    @Test("The reader hands back the roots the UI resolves paths against")
    func sourceRoots() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let first = try await fixture.addSource("Camera", volume: "vol-1")
        let second = try await fixture.addSource("Phone", volume: "vol-2")

        let roots = try await fixture.reader.rootURLs()
        #expect(roots[first.id]?.path == "/Volumes/Camera")
        #expect(roots[second.id]?.path == "/Volumes/Phone")
    }

    @Test("Items come back by id in the order the caller asked for selection state")
    func itemsByIds() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([
            makeItem("a.JPG", documentID: 1, sourceID: source.id),
            makeItem("b.JPG", documentID: 2, sourceID: source.id),
        ])
        let fetched = try await fixture.reader.items(ids: [ids[1], ids[0]])
        #expect(Set(fetched.map(\.id)) == Set(ids))
        #expect(try await fixture.reader.items(ids: []).isEmpty)
    }
}
