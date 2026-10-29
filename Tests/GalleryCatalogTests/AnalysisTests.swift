import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain
import GallerySQLite

@Suite("Analysis schema and search")
struct AnalysisTests {
    private func analysis(_ id: MediaID, ocr: String? = nil, tags: [String] = [],
                          aesthetic: Double = 0, dhash: UInt64? = nil,
                          utility: Bool = false) -> MediaAnalysisResult {
        MediaAnalysisResult(
            mediaID: id,
            statHash: 1,
            version: 1,
            revision: "test",
            ocrText: ocr,
            ocrBlockCount: ocr == nil ? 0 : 1,
            aesthetic: aesthetic,
            isUtility: utility,
            tags: tags,
            dhash: dhash
        )
    }

    @Test("A v2 library walks forward to v3 with its rows, and the two shapes agree column for column")
    func v2WalksForwardToV3() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        try await fixture.record([makeItem("kyoto_2024.JPG", documentID: 1, sourceID: source.id)])

        // Put the database back exactly as v2 left it.
        let downgraded = try SQLiteHandle.open(path: fixture.databaseURL.path, kind: .readWrite)
        try downgraded.write {
            try downgraded.downgradeToV2()
            try downgraded.setUserVersion(2)
        }

        // Reopening runs the ladder. A second, freshly created catalog is the reference shape.
        _ = try await fixture.reopened()
        let referenceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-schema-reference-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: referenceURL) }
        _ = try Catalog.open(at: referenceURL)

        let migrated = try columns(of: fixture.databaseURL, table: "media")
        let fresh = try columns(of: referenceURL, table: "media")
        #expect(migrated == fresh, "ALTER TABLE and Schema.create have to agree column for column")

        let fts = try columns(of: fixture.databaseURL, table: "media_fts")
        #expect(fts == ["name", "place_key", "device", "lens", "search_text", "search_tags", "search_ocr"])

        // The row written before the upgrade is still searchable through the recreated index.
        let reader = try CatalogReader.open(at: fixture.databaseURL)
        let hits = try await reader.search("kyoto")
        #expect(hits.count == 1, "the rebuild after the migration reindexed the old rows")
    }

    private func columns(of url: URL, table: String) throws -> [String] {
        let handle = try SQLiteHandle.open(path: url.path, kind: .readOnly)
        return try handle.query("PRAGMA table_info(\(table))").compactMap { row in
            try? row.string(named: "name")
        }
    }

    @Test("Recognised text ranks below a filename and above the file's own vocabulary")
    func ocrRanking() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([
            makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id),
            makeItem("invoice_2024.JPG", documentID: 2, sourceID: source.id),
            makeItem("IMG_0002.JPG", documentID: 3, sourceID: source.id),
        ])

        // Both non-name hits have to be *finished* rows before analysis will take them.
        let stored = try await fixture.reader.items(ids: ids)
        try await fixture.metadata([
            stored[0].decoded(),
            stored[2].decoded(search: "invoice document"),
        ])
        try await fixture.catalog.recordAnalysis([analysis(ids[0], ocr: "Invoice total 42.00")])

        let reader = fixture.reader
        let hits = try await reader.search("invoice")
        #expect(hits.count == 3)
        #expect(hits.map(\.item.id) == [ids[1], ids[0], ids[2]],
                "name, then recognised text, then the file's own vocabulary")
        #expect(hits[1].matched == .recognizedText)
        #expect(hits[1].snippet.contains("Invoice"))
    }

    @Test("Writing the same analysis twice is idempotent, and a changed file loses its derived text")
    func analysisIsIdempotentAndClears() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id)])
        let stored = try await fixture.reader.items(ids: ids)
        try await fixture.metadata(stored.map { $0.decoded() })

        try await fixture.catalog.recordAnalysis([analysis(ids[0], ocr: "receipt total")])
        let first = try await fixture.reader.search("receipt")
        try await fixture.catalog.recordAnalysis([analysis(ids[0], ocr: "receipt total")])
        let second = try await fixture.reader.search("receipt")

        #expect(first.count == 1 && second.count == 1, "a re-run must not duplicate the row or the text")
        #expect(first[0].snippet == second[0].snippet)
        #expect(first[0].rank == second[0].rank)

        // The same file, new bytes: the enumeration upsert resets the analysis stage, and the clear removes
        // the text that no longer describes it.
        try await fixture.record([makeItem("IMG_0001.JPG", documentID: 1, sourceID: source.id, size: 4096)])
        try await fixture.catalog.clearStaleSearchText(sourceID: source.id)
        #expect(try await fixture.reader.search("receipt").isEmpty)
    }

    @Test("Tag albums are the rows carrying the tag, with the best-scoring one as cover")
    func tagAlbums() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record((0..<3).map {
            makeItem("IMG_\($0).JPG", documentID: Int64($0 + 1), sourceID: source.id)
        })
        let stored = try await fixture.reader.items(ids: ids)
        try await fixture.metadata(stored.map { $0.decoded() })
        try await fixture.catalog.recordAnalysis([
            analysis(ids[0], tags: ["food"], aesthetic: 0.2),
            analysis(ids[1], tags: ["food"], aesthetic: 0.9),
            analysis(ids[2], tags: ["documents"], aesthetic: 0.4),
        ])

        #expect(try await fixture.reader.count(album: .tag(TagKey(slug: "food"))) == 2)
        let albums = try await fixture.reader.tagAlbums(minimumItems: 2)
        #expect(albums.count == 1)
        let food = try #require(albums.first)
        #expect(food.title == "Food")
        #expect(food.itemCount == 2)
        #expect(food.coverMediaID == ids[1], "the highest-aesthetic member is the cover")
    }

    @Test("The analysis cursor claims finished rows only, newest first, and counts what is left")
    func analysisCursor() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record([
            makeItem("old.JPG", documentID: 1, sourceID: source.id),
            makeItem("new.JPG", documentID: 2, sourceID: source.id),
        ])
        // Only pass B's output is analysable; a stub row must not be claimed.
        let stored = try await fixture.reader.items(ids: ids)
        try await fixture.metadata([stored[0].decoded()])

        let jobs = try await fixture.catalog.claimAnalysis(limit: 10)
        #expect(jobs.map(\.mediaID) == [ids[0]], "the half-indexed row is not analysis work yet")

        var counts = try await fixture.catalog.analysisCounts(sourceID: source.id)
        #expect(counts.done == 0 && counts.pending == 1 && counts.parked == 0)

        try await fixture.catalog.recordAnalysis([analysis(ids[0], tags: ["nature"])])
        counts = try await fixture.catalog.analysisCounts(sourceID: source.id)
        #expect(counts.done == 1 && counts.pending == 0)

        // A claimed row that is released goes back to pending; a parked one stops being claimed.
        try await fixture.metadata([stored[1].decoded()])
        let claimed = try await fixture.catalog.claimAnalysis(limit: 10)
        #expect(claimed.map(\.mediaID) == [ids[1]])
        try await fixture.catalog.parkClaims([ids[1]])
        counts = try await fixture.catalog.analysisCounts(sourceID: source.id)
        #expect(counts.done == 1 && counts.pending == 0 && counts.parked == 1)
        #expect(try await fixture.catalog.claimAnalysis(limit: 10).isEmpty)
    }

    @Test("A duplicate set keeps the best shot, never a utility one, and dies below two members")
    func duplicateGroups() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let source = try await fixture.addSource()
        let ids = try await fixture.record((0..<3).map {
            makeItem("IMG_\($0).JPG", documentID: Int64($0 + 1), sourceID: source.id)
        })
        let stored = try await fixture.reader.items(ids: ids)
        try await fixture.metadata(stored.map { $0.decoded() })
        try await fixture.catalog.recordAnalysis([
            analysis(ids[0], aesthetic: 0.2, dhash: 0xFF00),
            analysis(ids[1], aesthetic: 0.9, dhash: 0xFF01),
            analysis(ids[2], aesthetic: 0.95, dhash: 0xFF03, utility: true),
        ])

        for id in ids {
            try await fixture.catalog.addToDuplicateGroup(groupID: 4242, mediaID: id, distance: 1)
        }

        let set = try #require(try await fixture.reader.duplicateSet(containing: ids[0]))
        #expect(set.best == ids[1], "the highest score wins, and a utility shot is never the keeper")
        #expect(Set(set.members) == Set(ids))
        #expect(try await fixture.reader.bestDuplicateIDs() == [ids[1]])

        let day = try #require(try await fixture.reader.item(id: ids[0])).dayBucket
        let candidates = try await fixture.catalog.duplicateCandidates(days: [day], excluding: [ids[0]])
        #expect(candidates.count == 2, "same-day rows with a hash, minus the one being analysed")

        // Two of the three leave: the set is no longer a set.
        try await fixture.catalog.deleteMedia(ids: [ids[1], ids[2]])
        try await fixture.catalog.pruneDuplicateGroups()
        #expect(try await fixture.catalog.duplicateGroupID(for: ids[0]) == nil)
        #expect(try await fixture.reader.bestDuplicateIDs().isEmpty)
    }
}
