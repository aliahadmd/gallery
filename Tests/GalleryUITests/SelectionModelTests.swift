import Foundation
import Testing
@testable import GalleryUI
import GalleryDomain

@Suite("Whole-album selection")
@MainActor struct SelectionModelTests {
    @Test("⌘A selects the whole album, not the loaded pages")
    func selectAllCoversTheAlbum() async throws {
        let fixture = try await Fixture(files: 450)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        #expect(fixture.model.items.count == 200)
        fixture.model.selectAll()
        #expect(fixture.model.isWholeAlbumSelection)
        #expect(fixture.model.selectedCount == 450)
        #expect(fixture.model.selectedIDs.count == 200,
                "the rings are drawn on the loaded page")

        let batch = try #require(fixture.model.batchSelection())
        #expect(batch.explicit == nil)
        #expect(batch.count == 450)
        #expect(batch.album == fixture.model.selection)
    }

    @Test("Excluding rows and inverting keeps exact counts")
    func exclusionsAndInvert() async throws {
        let fixture = try await Fixture(files: 20)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        fixture.model.selectAll()
        let first = try #require(fixture.model.items.first)
        fixture.model.select(first.id, extending: true)
        #expect(fixture.model.selectedCount == 19)
        #expect(fixture.model.isWholeAlbumSelection)

        fixture.model.invertSelection()
        #expect(fixture.model.selectedCount == 1)
        #expect(!fixture.model.isWholeAlbumSelection)
        #expect(fixture.model.selectedIDs == [first.id])

        fixture.model.deselectAll()
        #expect(fixture.model.selectedCount == 0)
        #expect(fixture.model.batchSelection() == nil)
    }

    @Test("A whole-album delete reaches every row, not just the page")
    func trashTheWholeAlbum() async throws {
        let fixture = try await Fixture(files: 450)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        let ids = Set(fixture.model.items.map(\.id))
        #expect(ids.count == 200)

        fixture.model.selectAll()
        await fixture.model.trashSelection()

        #expect(fixture.model.rowCount == 0)
        #expect(fixture.model.selectedCount == 0)
        await fixture.model.select(.recentlyDeleted)
        #expect(fixture.model.rowCount == 450, "every row is in Recently Deleted, not just 200")
    }

    @Test("An explicit selection survives a reload and a rescan")
    func explicitSelectionSurvivesReload() async throws {
        let fixture = try await Fixture(files: 450)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        let first = try #require(fixture.model.items.first)
        let second = try #require(fixture.model.items.dropFirst().first)
        fixture.model.select(first.id)
        fixture.model.select(second.id, extending: true)
        #expect(fixture.model.selectedCount == 2)

        await fixture.model.reload()
        #expect(fixture.model.selectedCount == 2,
                "the ids are still in the album even though the page was re-read")
        #expect(fixture.model.selectedIDs == [first.id, second.id])
    }

    @Test("The expand entry asks the viewer for fullscreen; a plain open does not")
    func viewerFullscreenRequest() async throws {
        let fixture = try await Fixture(files: 3)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        let id = try #require(fixture.model.items.first).id

        fixture.model.openViewer(id)
        #expect(!fixture.model.viewerWantsFullscreen)

        fixture.model.closeViewer()
        fixture.model.openViewer(id, fullscreen: true)
        #expect(fixture.model.viewerWantsFullscreen)

        fixture.model.consumeFullscreenRequest()
        #expect(!fixture.model.viewerWantsFullscreen)
        fixture.model.closeViewer()
    }

    @Test("Invert during a search stays inside the hits")
    func invertDuringSearchStaysInsideTheHits() async throws {
        let fixture = try await Fixture(files: 12)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        fixture.model.updateSearch("photo_1")
        try await fixture.waitUntil { fixture.model.isSearching }
        let hits = Set(fixture.model.items.map(\.id))
        #expect(!hits.isEmpty)
        let first = try #require(fixture.model.items.first)
        fixture.model.select(first.id)
        fixture.model.invertSelection()

        #expect(fixture.model.selectedCount == hits.count - 1)
        #expect(fixture.model.selectedIDs.isSubset(of: hits),
                "an inversion cannot select rows outside the search")
    }

    @Test("Typing a search starts a new selection scope")
    func searchResetsSelection() async throws {
        let fixture = try await Fixture(files: 30)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        fixture.model.selectAll()
        #expect(fixture.model.selectedCount == 30)

        fixture.model.updateSearch("photo_1")
        try await fixture.waitUntil { fixture.model.isSearching }
        #expect(fixture.model.selectedCount == 0,
                "a search is a different scope; the old album selection cannot leak into it")
        #expect(!fixture.model.isWholeAlbumSelection)
    }

    @Test("A whole-album batch follows the grid's sort, not row ids")
    func wholeAlbumBatchFollowsGridSort() async throws {
        let fixture = try await Fixture(files: 8)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        fixture.model.sort = MediaSort(field: .fileName, order: .descending)
        await fixture.model.reload()
        let visible = fixture.model.items.map(\.name)
        #expect(visible == visible.sorted(by: >), "the grid is actually in the sort being tested")

        fixture.model.selectAll()
        let batch = try #require(fixture.model.batchSelection())
        #expect(batch.isWholeAlbum)
        let resolved = await fixture.model.resolveRows(batch)
        #expect(resolved.rows.map(\.name) == visible,
                "a rename sequence must number the rows in the order the user sees")
    }

    @Test("A batch keeps the selection's order, so a rename sequence numbers what the user sees")
    func batchRowsKeepExplicitOrder() async throws {
        let fixture = try await Fixture(files: 6)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        // Deliberately the reverse of rowid/grid order: a `WHERE id IN` comes back in table order, and a
        // sequence built from that would number the photos backwards.
        let reversed = fixture.model.items.map(\.id).reversed().map { $0 }
        let batch = BatchSelection(album: .all, explicit: reversed, count: reversed.count)
        let resolved = await fixture.model.resolveRows(batch)
        #expect(resolved.rows.map(\.id) == reversed)
        #expect(!resolved.isTruncated)

        let capped = await fixture.model.resolveRows(batch, limit: 2)
        #expect(capped.rows.map(\.id) == Array(reversed.prefix(2)))
        #expect(capped.isTruncated, "an action that cannot cover the selection has to say so")
    }
}
