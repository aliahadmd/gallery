import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain

@Suite("Selection queries")
struct SelectionQueryTests {
    @Test("Id pages walk the album in ascending order and respect the frozen upper bound")
    func idPages() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record(
            (1...5).map { makeItem("IMG_\($0).JPG", documentID: Int64($0), sourceID: source.id) }
        )

        let first = try await fixture.reader.ids(album: .all, limit: 2)
        #expect(first.ids == [ids[0], ids[1]])
        #expect(first.hasMore)

        let second = try await fixture.reader.ids(album: .all, after: first.ids.last, limit: 2)
        #expect(second.ids == [ids[2], ids[3]])

        let third = try await fixture.reader.ids(album: .all, after: second.ids.last, limit: 2)
        #expect(third.ids == [ids[4]])
        #expect(!third.hasMore)

        let bounded = try await fixture.reader.ids(album: .all, upperBound: ids[1], limit: 10)
        #expect(bounded.ids == [ids[0], ids[1]], "rows beyond the frozen bound are excluded")

        let maxID = try await fixture.reader.maxMediaID()
        #expect(maxID == ids[4])
    }

    @Test("Item pages carry the same rows as the id pages")
    func itemPages() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record(
            (1...4).map { makeItem("IMG_\($0).JPG", documentID: Int64($0), sourceID: source.id) }
        )
        let page = try await fixture.reader.items(album: .all, after: nil, upperBound: nil, limit: 3)
        #expect(page.map(\.id) == [ids[0], ids[1], ids[2]])
        let rest = try await fixture.reader.items(album: .all, after: page.last?.id, upperBound: nil, limit: 3)
        #expect(rest.map(\.id) == [ids[3]])
    }

    @Test("Among-ids pruning answers album membership, not page membership")
    func amongIDs() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record(
            (1...4).map { makeItem("IMG_\($0).JPG", documentID: Int64($0), sourceID: source.id) }
        )
        try await fixture.catalog.setFavorite(ids[1], true)
        try await fixture.catalog.setFavorite(ids[3], true)

        let alive = try await fixture.reader.ids(in: .favorites, among: ids)
        #expect(alive == [ids[1], ids[3]])

        let all = try await fixture.reader.ids(in: .all, among: ids + [MediaID(rawValue: 9_999)])
        #expect(all == Set(ids))
    }

    @Test("The selection summary counts images, videos, bytes and favorites")
    func summary() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([
            makeItem("a.JPG", documentID: 1, sourceID: source.id, size: 100),
            makeItem("b.JPG", documentID: 2, sourceID: source.id, size: 200),
            makeItem("c.MOV", documentID: 3, sourceID: source.id, kind: .video, size: 300),
        ])
        try await fixture.catalog.setFavorite(ids[0], true)

        let summary = try await fixture.reader.selectionSummary(album: .all)
        #expect(summary.total == 3)
        #expect(summary.images == 2)
        #expect(summary.videos == 1)
        #expect(summary.byteSize == 600)
        #expect(summary.favorites == 1)
        #expect(try await fixture.reader.selectionSummary(album: .favorites).total == 1)
    }
}
