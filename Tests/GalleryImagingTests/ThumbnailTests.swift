import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GalleryImaging
import GalleryDomain

@Suite("Thumbnail buckets")
struct ThumbnailBucketTests {
    @Test("The buckets go up in size, which is what `best` walks")
    func ordering() {
        let sides = ThumbnailBucket.allCases.map(\.longSide)
        #expect(sides == sides.sorted())
        #expect(ThumbnailBucket.list < .viewerMax)
    }

    @Test("A request lands in the smallest bucket that covers it")
    func selection() {
        // The edges matter more than the middles: one pixel over a bucket's side must not borrow the
        // bucket below it and draw a scaled-up blur.
        for (need, bucket) in [(0, ThumbnailBucket.list), (96, .list), (97, .gridSmall),
                               (160, .gridSmall), (161, .gridLarge), (320, .gridLarge),
                               (321, .viewerHalf), (2048, .viewerFull), (2049, .viewerMax),
                               (4096, .viewerMax), (60_000, .viewerMax)] {
            #expect(ThumbnailBucket.best(longSide: need) == bucket, "need \(need)")
        }
    }

    @Test("A Retina cell is never served the bucket its non-Retina twin would ask for")
    func cellPoints() {
        #expect(ThumbnailBucket.best(cellPoints: 110, scale: 1) == .gridSmall)
        #expect(ThumbnailBucket.best(cellPoints: 110, scale: 2) == .gridLarge)
        #expect(ThumbnailBucket.best(cellPoints: 48, scale: 2) == .list)
    }
}

@Suite("Thumbnail disk layout")
struct ThumbnailLayoutTests {
    let root = URL(fileURLWithPath: "/tmp/gallery-layout")

    @Test("The path is bucket, shard, then the identity including its invalidation stamp")
    func path() {
        let layout = ThumbnailLayout(root: root)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let url = layout.url(mediaID: MediaID(rawValue: 300), bucket: .gridLarge, mtime: mtime)
        // 300 & 0xFF is 0x2c — the shard is what keeps 600k files out of one directory.
        #expect(url.path == "/tmp/gallery-layout/thumbs/320/2c/300-\(mtime.nanoseconds).jpg")
    }

    @Test("A file with no modification date still gets a stable name")
    func noStamp() {
        let layout = ThumbnailLayout(root: root)
        let url = layout.url(mediaID: MediaID(rawValue: 7), bucket: .list, mtime: nil)
        #expect(url.lastPathComponent == "7-0.jpg")
    }

    @Test("A re-stamped photo is a different file, which is the whole invalidation policy")
    func restampingIsAMiss() {
        let layout = ThumbnailLayout(root: root)
        let old = layout.url(mediaID: MediaID(rawValue: 9), bucket: .gridSmall,
                             mtime: Date(timeIntervalSince1970: 1))
        let new = layout.url(mediaID: MediaID(rawValue: 9), bucket: .gridSmall,
                             mtime: Date(timeIntervalSince1970: 2))
        #expect(old != new)
    }

    @Test("Neighbouring ids share a shard only when their low byte says so")
    func shards() {
        let layout = ThumbnailLayout(root: root)
        let directory = layout.directory(bucket: .viewerFull, mediaID: MediaID(rawValue: 256))
        #expect(directory.lastPathComponent == "00")
        #expect(layout.directory(bucket: .viewerFull, mediaID: MediaID(rawValue: 255))
                .lastPathComponent == "ff")
        #expect(layout.directory(bucket: .gridSmall, mediaID: MediaID(rawValue: 1)).pathComponents
                .suffix(3).elementsEqual(["thumbs", "160", "01"]))
    }
}

@Suite("Thumbnail baking")
struct ThumbnailBakerTests {
    let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    @Test("The baked image is the bucket, not the source")
    func bakesToBucketSize() throws {
        var fixture = ImageFixture()
        fixture.width = 1280
        fixture.height = 960
        let url = try fixture.write(into: scratch.directory, named: "big")

        let data = try #require(ThumbnailBaker.bake(url: url, bucket: .gridLarge))
        let image = try #require(ThumbnailBaker.image(from: data))
        #expect(image.width == 320)
        #expect(image.height == 240)
        // A 320 px JPEG has to be small enough that 100k of them is a cache and not a second library.
        #expect(data.count < 60_000)
    }

    @Test("Orientation is applied while baking, so the cell never has to rotate it")
    func bakesUpright() throws {
        var fixture = ImageFixture()
        fixture.width = 640
        fixture.height = 480
        fixture.orientation = 6
        let url = try fixture.write(into: scratch.directory, named: "rotated")

        let data = try #require(ThumbnailBaker.bake(url: url, bucket: .gridLarge))
        let image = try #require(ThumbnailBaker.image(from: data))
        // Stored 4:3 landscape with a 6 on it means displayed portrait — the same swap the grid's aspect
        // ratio makes, made here once instead of in every cell that draws it.
        #expect(image.width == 240)
        #expect(image.height == 320)
    }

    @Test("Each bucket is its own image")
    func everyBucket() throws {
        var fixture = ImageFixture()
        fixture.width = 4000
        fixture.height = 3000
        let url = try fixture.write(into: scratch.directory, named: "huge")
        for bucket in ThumbnailBucket.allCases {
            let data = try #require(ThumbnailBaker.bake(url: url, bucket: bucket))
            let image = try #require(ThumbnailBaker.image(from: data))
            let longSide = max(image.width, image.height)
            let ratio = Double(image.width) / Double(image.height)
            // A bucket is a ceiling, never a floor: ImageIO does not enlarge, so a 4000 px source asked for
            // at 4096 comes back at its own size rather than as an upscaled blur.
            #expect(longSide == min(Int(bucket.longSide), 4000), "\(bucket)")
            // Downsampled, not squashed: the aspect ratio is what every cell layout in the app depends on.
            #expect(abs(ratio - 4.0 / 3.0) < 0.02, "\(bucket)")
        }
    }

    @Test("A file ImageIO cannot produce a picture from bakes nothing")
    func nothingToBake() throws {
        let garbage = try scratch.file("junk.jpg", Data("not a jpeg".utf8))
        #expect(ThumbnailBaker.bake(url: garbage, bucket: .gridSmall) == nil)
        #expect(ThumbnailBaker.bake(url: scratch.url("never-existed.jpg"), bucket: .gridSmall) == nil)
    }
}

@Suite("Thumbnail cache on disk")
struct ThumbnailStoreTests {
    let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    private func store(byteLimit: Int64 = 4 * 1024 * 1024) -> ThumbnailStore {
        ThumbnailStore(layout: ThumbnailLayout(root: scratch.directory), byteLimit: byteLimit)
    }

    @Test("A saved thumbnail comes back, and a different stamp does not")
    func roundTrip() throws {
        let cache = store()
        let id = MediaID(rawValue: 41)
        let first = Date(timeIntervalSince1970: 1_000)
        try cache.save(Data([1, 2, 3]), mediaID: id, bucket: .gridSmall, mtime: first)

        #expect(cache.load(mediaID: id, bucket: .gridSmall, mtime: first) == Data([1, 2, 3]))
        #expect(cache.load(mediaID: id, bucket: .gridSmall, mtime: Date(timeIntervalSince1970: 1_001)) == nil)
        // The bucket is part of the identity: a 320 must never satisfy a 96 and blur a list row.
        #expect(cache.load(mediaID: id, bucket: .list, mtime: first) == nil)
    }

    @Test("Removing a picture takes every bucket and every stale stamp with it")
    func removeEveryCopy() throws {
        let cache = store()
        let id = MediaID(rawValue: 42)
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        for bucket in [ThumbnailBucket.list, .gridSmall, .gridLarge] {
            try cache.save(Data(count: 32), mediaID: id, bucket: bucket, mtime: old)
            try cache.save(Data(count: 32), mediaID: id, bucket: bucket, mtime: new)
        }
        let neighbour = MediaID(rawValue: 298)
        try cache.save(Data(count: 32), mediaID: neighbour, bucket: .gridSmall, mtime: new)
        #expect(cache.usedBytes() > 0)

        cache.removeAll(mediaID: id)

        for bucket in ThumbnailBucket.allCases {
            #expect(cache.load(mediaID: id, bucket: bucket, mtime: old) == nil)
            #expect(cache.load(mediaID: id, bucket: bucket, mtime: new) == nil)
        }
        // 298 sits in 42's shard (both end 0x2a), so this is the test that the match is on the id and not
        // merely on the directory.
        #expect(cache.load(mediaID: neighbour, bucket: .gridSmall, mtime: new) != nil)
    }

    @Test("The budget evicts the coldest file it is told about and stops at the line")
    func evictToBudget() throws {
        let cache = store(byteLimit: 2_500)
        let mtime = Date(timeIntervalSince1970: 5_000)
        let cold = MediaID(rawValue: 1)
        let middle = MediaID(rawValue: 2)
        let warm = MediaID(rawValue: 3)
        var built: [String: Date] = [:]
        for (id, used) in [(cold, 100.0), (middle, 200.0), (warm, 300.0)] {
            try cache.save(Data(count: 1_000), mediaID: id, bucket: .gridSmall, mtime: mtime)
            built[cache.layout.url(mediaID: id, bucket: .gridSmall, mtime: mtime).path] =
                Date(timeIntervalSince1970: used)
        }
        let dates = built

        let report = cache.evict { dates[$0.path] }
        #expect(report.removed == 1)
        #expect(report.freedBytes == 1_000)
        #expect(cache.load(mediaID: cold, bucket: .gridSmall, mtime: mtime) == nil)
        #expect(cache.load(mediaID: warm, bucket: .gridSmall, mtime: mtime) != nil)
        #expect(cache.usedBytes() <= 2_500)
    }

    @Test("An undated file is the last one evicted, and a flush takes them all")
    func undatedSurvivesUntilTheEnd() throws {
        let cache = store(byteLimit: 500)
        let mtime = Date(timeIntervalSince1970: 5_000)
        try cache.save(Data(count: 1_000), mediaID: MediaID(rawValue: 1), bucket: .gridSmall, mtime: mtime)
        try cache.save(Data(count: 1_000), mediaID: MediaID(rawValue: 2), bucket: .gridSmall, mtime: mtime)

        // Disk-budget says the manifest does not know these two, so neither can be proven cold; the sweep
        // still has to reach the budget, and it gets there by removing both.
        let first = cache.evict(lastUsed: { _ in nil })
        #expect(first.removed == 2)
        #expect(cache.usedBytes() == 0)

        try cache.save(Data(count: 1_000), mediaID: MediaID(rawValue: 3), bucket: .gridSmall, mtime: mtime)
        #expect(cache.evict(untilUnderBudget: false, lastUsed: { _ in Date() }).removed == 1)
        #expect(cache.usedBytes() == 0)
    }

    @Test("The budget is the smaller of the cap and a share of what the volume has free")
    func budgetSizing() {
        let cap: Int64 = 4 * 1024 * 1024 * 1024
        let measured = ThumbnailStore.byteLimit(for: scratch.directory, cap: cap)
        #expect(measured > 0)
        #expect(measured <= cap)
        // A path with no volume behind it gets the cap rather than zero, which would switch the cache off.
        #expect(ThumbnailStore.byteLimit(for: URL(fileURLWithPath: "/no/such/place/here"), cap: cap) == cap)
    }
}
