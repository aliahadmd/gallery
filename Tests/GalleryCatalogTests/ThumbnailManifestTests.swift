import Foundation
import Testing
@testable import GalleryCatalog
import GalleryDomain

@Suite("Thumbnail manifest")
struct ThumbnailManifestTests {
    private func record(_ id: Int64, _ bucket: ThumbnailBucket = .gridSmall, mtime: Date?,
                        bytes: Int64, used: TimeInterval) -> ThumbnailRecord {
        ThumbnailRecord(mediaID: MediaID(rawValue: id), bucket: bucket, mtime: mtime,
                        path: "/cache/thumbs/\(bucket.longSide)/\(id)-\(mtime?.nanoseconds ?? 0).jpg",
                        byteSize: bytes, lastUsed: Date(timeIntervalSince1970: used))
    }

    @Test("A note is the row the cache looks up again")
    func noteRoundTrip() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let mtime = Date(timeIntervalSince1970: 1_000)

        try await fixture.catalog.noteThumbnail(record(7, mtime: mtime, bytes: 20_000, used: 500))

        let coldest = try await fixture.catalog.coldestThumbnails(limit: 10)
        let found = try #require(coldest.first)
        #expect(found.mediaID == MediaID(rawValue: 7))
        #expect(found.bucket == .gridSmall)
        #expect(abs(found.mtime!.timeIntervalSince(mtime)) < 0.001)
        #expect(found.byteSize == 20_000)
        #expect(found.path.contains("/160/"))
        #expect(try await fixture.catalog.thumbnailManifestBytes() == 20_000)
    }

    @Test("Re-baking the same stamp corrects the row instead of duplicating it")
    func reBakeUpdatesInPlace() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let mtime = Date(timeIntervalSince1970: 1_000)

        try await fixture.catalog.noteThumbnail(record(8, mtime: mtime, bytes: 100, used: 1))
        let repaired = record(8, mtime: mtime, bytes: 24_000, used: 9_000)
        try await fixture.catalog.noteThumbnail(repaired)

        #expect(try await fixture.catalog.thumbnailRecordCount() == 1)
        #expect(try await fixture.catalog.thumbnailManifestBytes() == 24_000)
        let coldest = try await fixture.catalog.coldestThumbnails(limit: 5)
        #expect(try #require(coldest.first).lastUsed == repaired.lastUsed)
    }

    @Test("A touch moves a row to the warm end of the eviction order")
    func touchReordersEviction() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let mtime = Date(timeIntervalSince1970: 1_000)
        for (id, used) in [(Int64(1), 100.0), (2, 200.0), (3, 300.0)] {
            try await fixture.catalog.noteThumbnail(record(id, mtime: mtime, bytes: 1_000, used: used))
        }
        #expect(try await fixture.catalog.coldestThumbnails(limit: 3).map(\.mediaID.rawValue) == [1, 2, 3])

        let touched = Date(timeIntervalSince1970: 400)
        try await fixture.catalog.touchThumbnail(mediaID: MediaID(rawValue: 1), bucket: .gridSmall,
                                                 mtime: mtime, path: "/cache/thumbs/160/1-1000000000000.jpg",
                                                 usedAt: touched)

        // The one the user just looked at is now the last thing eviction would take.
        #expect(try await fixture.catalog.coldestThumbnails(limit: 3).map(\.mediaID.rawValue) == [2, 3, 1])
        // And a touch cannot rewrite the bytes it is only keeping warm.
        #expect(try await fixture.catalog.thumbnailManifestBytes() == 3_000)
    }

    @Test("A touch for a bucket that was never noted still points at a file")
    func touchWithoutNote() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }

        try await fixture.catalog.touchThumbnail(mediaID: MediaID(rawValue: 5), bucket: .viewerFull,
                                                 mtime: nil, path: "/cache/thumbs/4096/5-0.jpg",
                                                 usedAt: Date(timeIntervalSince1970: 7))
        let rows = try await fixture.catalog.coldestThumbnails(limit: 5)
        let row = try #require(rows.first)
        #expect(row.mtime == nil)
        #expect(row.bucket == .viewerFull)
        #expect(row.byteSize == 0)
        #expect(row.lastUsed == Date(timeIntervalSince1970: 7))
    }

    @Test("Two stamps of one photo are two rows, and the cold one can be dropped with its file")
    func staleStampIsARowOfItsOwn() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let old = record(9, mtime: Date(timeIntervalSince1970: 1), bytes: 1_000, used: 1)
        let fresh = record(9, mtime: Date(timeIntervalSince1970: 2), bytes: 1_000, used: 2)
        try await fixture.catalog.noteThumbnail(old)
        try await fixture.catalog.noteThumbnail(fresh)
        #expect(try await fixture.catalog.thumbnailRecordCount() == 2)

        try await fixture.catalog.deleteThumbnailRows(paths: [old.path])

        let rows = try await fixture.catalog.coldestThumbnails(limit: 5)
        #expect(rows.map(\.path) == [fresh.path])
    }

    @Test("Deleting a picture clears every bucket it had")
    func deleteByMedia() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let mtime = Date(timeIntervalSince1970: 1_000)
        for bucket in [ThumbnailBucket.list, .gridSmall, .gridLarge] {
            try await fixture.catalog.noteThumbnail(record(11, bucket, mtime: mtime, bytes: 500, used: 1))
        }
        try await fixture.catalog.noteThumbnail(record(12, mtime: mtime, bytes: 500, used: 1))

        try await fixture.catalog.deleteThumbnailRows(mediaID: MediaID(rawValue: 11))

        let rows = try await fixture.catalog.coldestThumbnails(limit: 10)
        #expect(rows.map(\.mediaID.rawValue) == [12])
    }

    @Test("An empty cache reads as zero, not as a missing row")
    func emptyManifest() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        #expect(try await fixture.catalog.thumbnailManifestBytes() == 0)
        #expect(try await fixture.catalog.thumbnailRecordCount() == 0)
        #expect(try await fixture.catalog.coldestThumbnails(limit: 10).isEmpty)
        try await fixture.catalog.deleteThumbnailRows(paths: [])
    }

    @Test("A file with no modification date is stored as stamp zero and read back as none")
    func noStamp() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        let row = record(13, mtime: nil, bytes: 900, used: 1)
        try await fixture.catalog.noteThumbnail(row)

        let read = try await fixture.catalog.coldestThumbnails(limit: 2)
        #expect(try #require(read.first).mtime == nil)
        #expect(try #require(read.first).path == row.path)
    }

    @Test("A date outside the stamp range clamps instead of trapping the write")
    func absurdDates() async throws {
        let fixture = try await CatalogFixture()
        defer { fixture.tearDown() }
        // The cases are not hypothetical: `0000-01-01` and `1601-01-01` come out of camera firmware, and a
        // sentinel like `Date.distantPast` is how a caller says "as cold as possible". All of them exceed
        // `Int64` nanoseconds, where the conversion used to crash.
        #expect(Date.distantPast.nanoseconds == .min)
        #expect(Date.distantFuture.nanoseconds == .max)
        #expect(Date(timeIntervalSinceReferenceDate: -12_622_272_000).nanoseconds == .min)
        #expect(Date(timeIntervalSinceReferenceDate: .nan).nanoseconds == 0)

        let row = record(14, mtime: .distantPast, bytes: 800, used: 1)
        try await fixture.catalog.noteThumbnail(row)
        let read = try #require(await fixture.catalog.coldestThumbnails(limit: 2).first)
        // The clamp is a fixed point, so a thumbnail named from an impossible date keeps the same name.
        #expect(read.mtime == Date(nanoseconds: .min))
        #expect(read.mtime?.nanoseconds == .min)
    }
}
