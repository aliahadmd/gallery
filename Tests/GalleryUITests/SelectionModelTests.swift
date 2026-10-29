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
}
