import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import GalleryIndexing
import GalleryCatalog
import GalleryDomain
import GalleryImaging
import GallerySupport

/// M3's exit numbers, measured rather than assumed.
///
/// Gated because a measurement is not a unit test: it writes tens of thousands of files, takes seconds to
/// minutes, and the answer depends on the machine. Run one test per process so the footprint belongs to that
/// run alone:
///
///     GALLERY_BENCH=1 swift test --package-path . --filter "pass A"
///
/// Knobs: `GALLERY_BENCH_ITEMS` (pass A file count, default 20 000), `GALLERY_BENCH_TREE` (walk an existing
/// tree instead of generating one, e.g. `build/qa-media`), `GALLERY_BENCH_PHOTOS` (real JPEGs planted for
/// pass B, default 1 000) and `GALLERY_BENCH_VIEWPORT` (cells on one screen, default 60). Every test prints
/// one `M3-BENCH` line so a run can be read without decoding test names.
@Suite("M3 measurements", .serialized, .enabled(if: Bench.isEnabled))
struct IndexingBenchmarkTests {
    /// The walk. Pass A is the process that sees every file, so its high-water mark is the one the
    /// "<500 MB" criterion is about — the catalog writes, the sweep and the batch buffers included.
    @Test("pass A: a large tree inside the memory budget")
    func passAWalk() async throws {
        let count = Bench.items
        let generated = Bench.existingTree == nil ? try stubTree(count: count) : nil
        defer { generated?.cleanup() }
        let root = try #require(Bench.existingTree ?? generated?.root)

        let library = try await CoordinatorFixture()
        defer { library.tearDown() }
        let source = try await library.coordinator.addFolder(root, scanning: false)

        let sampler = FootprintSampler()
        let baseline = await sampler.start()
        let start = ContinuousClock.now
        let outcome = await library.coordinator.scan(source.id)
        let elapsed = ContinuousClock.now - start
        let peak = await sampler.stop()

        let rate = Double(outcome.discovered) / max(elapsed.inSeconds, 0.001)
        Bench.note(String(format: "pass-A items=%d written=%d dirs=%d seconds=%.2f rate=%.0f/s "
                         + "footprint=%.0fMB peak=%.0fMB root=%@",
                         outcome.discovered, outcome.written, outcome.directoriesListed,
                         elapsed.inSeconds, rate, baseline, peak, root.lastPathComponent))

        #expect(outcome.failure == nil, "\(outcome.failure ?? "")")
        #expect(outcome.written == outcome.discovered, "every media file the walk found reached the grid")
        if generated != nil {
            #expect(outcome.discovered == count)
        }
        #expect(peak < 500, "the walk's high-water mark has to stay under half a gigabyte")
    }

    /// Pass B with nothing competing for the queue: the rate is per photo, read then baked.
    @Test("pass B: the backlog drains at a measured rate")
    func passBDrain() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let photos = try await plantPhotos(in: library, count: Bench.photos)
        try await library.catalog.enqueuePendingWork(sourceID: library.sourceID)

        let worker = drainWorker(library, batchRows: 64)
        let sampler = FootprintSampler()
        let baseline = await sampler.start()
        let start = ContinuousClock.now
        let outcome = await worker.drain()
        let elapsed = ContinuousClock.now - start
        let peak = await sampler.stop()

        let rate = Double(outcome.postersRecorded) / max(elapsed.inSeconds, 0.001)
        Bench.note(String(format: "pass-B photos=%d read=%d posters=%d seconds=%.2f rate=%.0f/s "
                         + "msPerPhoto=%.1f footprint=%.0fMB peak=%.0fMB",
                         photos.count, outcome.metadataRead, outcome.postersRecorded,
                         elapsed.inSeconds, rate, elapsed.inSeconds * 1000 / Double(photos.count),
                         baseline, peak))

        #expect(outcome.failures == 0 && outcome.parked == 0)
        #expect(outcome.metadataRead == photos.count)
        #expect(outcome.postersRecorded == photos.count, "every row got the preview the grid will draw")
        #expect(try await library.catalog.queuedWorkCount(sourceID: library.sourceID) == 0)
    }

    /// The headline: a screenful of cells scrolls into view while the drain is working through a library
    /// far larger than one screen, and the question is how long until all of them can be drawn. The clock
    /// runs from the claim that follows the raise to the last cell's bitmap in hand — the cache file landing
    /// is not the same event as the cell being drawable, and the grid waits on the second.
    @Test("view: a screenful is drawn inside a second, ahead of the backlog")
    func viewportFillLatency() async throws {
        let library = try await ServiceFixture()
        defer { library.tearDown() }
        let photos = try await plantPhotos(in: library, count: Bench.photos)
        try await library.catalog.enqueuePendingWork(sourceID: library.sourceID)

        let store = library.store()
        let service = library.service()
        let worker = drainWorker(library, batchRows: 64, thumbnails: service)

        // The oldest rows sit at the queue's tail: without the raise they are the last thing the drain
        // reaches. Raising before the first claim is the state the model produces in practice — its window
        // report is debounced by 120 ms, so a scroll's raise lands between hops, not inside one.
        let visible = Array(photos
            .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            .prefix(Bench.viewport))
        var stillQueued = 0
        for item in visible where (try? await library.reader.item(id: item.id))?.stage != .thumbnailed {
            stillQueued += 1
        }
        guard stillQueued == visible.count else {
            Issue.record("only \(stillQueued)/\(visible.count) viewport rows were queued; the fixture is too small")
            return
        }
        let requests = visible.map { ThumbnailService.Request(item: $0) }
        await worker.raisePriority(mediaIDs: visible.map(\.id))

        let start = ContinuousClock.now
        await worker.start()
        let posted = await poll(timeout: .seconds(30), until: {
            requests.allSatisfy {
                FileManager.default.fileExists(atPath: store.layout
                    .url(mediaID: $0.mediaID, bucket: .gridLarge, mtime: $0.mtime).path)
            }
        })
        // What a cell actually awaits: memory misses, so this is the disk tier answering — the same path a
        // tile takes ten minutes after the scan, not a special case for the benchmark.
        var drawn = 0
        await withTaskGroup(of: Bool.self) { group in
            for request in requests {
                group.addTask { await service.image(request, bucket: .gridLarge) != nil }
            }
            for await ok in group where ok { drawn += 1 }
        }
        let elapsed = ContinuousClock.now - start
        await worker.cancel()

        let backlog = (try? await library.catalog.stageCounts(sourceID: library.sourceID))?[.thumbnailed] ?? 0
        Bench.note(String(format: "view cells=%d posted=%@ drawn=%d seconds=%.3f backlogAfter=%d/%d",
                          visible.count, posted ? "yes" : "no", drawn, elapsed.inSeconds,
                          backlog, photos.count))

        #expect(posted, "the raised rows never all reached the cache")
        #expect(drawn == visible.count, "every raised cell found its bitmap")
        #expect(elapsed.inSeconds <= 1.0, "the viewport change has to be drawn inside a second")
        #expect(backlog < photos.count, "the fill must have jumped a live queue rather than waited for it to end")
    }
}

// MARK: - Fixtures

private func drainWorker(_ library: ServiceFixture, batchRows: Int,
                         thumbnails: ThumbnailService? = nil) -> MetadataWorker {
    MetadataWorker(catalog: library.catalog, reader: library.reader,
                   resolver: CatalogMediaResolver(reader: library.reader, bookmarks: library.bookmarks),
                   thumbnails: thumbnails ?? library.service(),
                   configuration: .init(batchRows: batchRows))
}

/// `count` stub files spread over folders, each with its own modification stamp.
///
/// Two bytes each, because pass A reads `stat` and nothing else: the number under measurement is the walk's
/// bookkeeping. Distinct stamps are not decoration — identity is the stat hash, so two files with one stamp
/// would upsert into one row and the walk would appear to invent less work than it did.
private func stubTree(count: Int, perFolder: Int = 500) throws -> FixtureTree {
    let tree = try FixtureTree(name: "bench-stubs")
    let base = Date(timeIntervalSince1970: 1_600_000_000)
    let stub = Data([0xFF, 0xD8])
    for start in stride(from: 0, to: count, by: perFolder) {
        let folder = try tree.folder("roll-\(start / perFolder)")
        for index in start..<min(count, start + perFolder) {
            let url = folder.appendingPathComponent("IMG_\(index).jpg")
            try stub.write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(index))], ofItemAtPath: url.path)
        }
    }
    return tree
}

/// Real JPEGs with real modification stamps, recorded as the rows pass A would have left — one batch, in
/// planting order, so the oldest picture is the queue's tail.
private func plantPhotos(in library: ServiceFixture, count: Int,
                         width: Int = 1280, height: Int = 960) async throws -> [MediaItem] {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var items: [MediaItem] = []
    items.reserveCapacity(count)
    for index in 0..<count {
        let relative = "roll-\(index / 200)/IMG_\(String(format: "%05d", index)).jpg"
        let url = library.tree.url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard writeBenchJPEG(to: url, width: width, height: height) else {
            throw BenchmarkError.writeFailed(url.path)
        }
        let modified = base.addingTimeInterval(Double(index))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let parent = (relative as NSString).deletingLastPathComponent
        items.append(MediaItem(
            id: MediaID(rawValue: 0),
            identity: FileIdentity(volumeID: "vol-1", documentID: nil, resourceID: nil,
                                   statHash: statHash(size: size, modificationDate: modified,
                                                      creationDate: nil)),
            sourceID: library.sourceID,
            relativePath: relative,
            parentDirectory: parent,
            name: (relative as NSString).lastPathComponent,
            fileExtension: "jpg",
            kind: .image,
            uniformTypeIdentifier: "public.jpeg",
            byteSize: size,
            modificationDate: modified
        ))
    }
    let ids = try await library.catalog.recordEnumeration(items)
    let stored = try await library.reader.items(ids: ids)
    let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
    return ids.compactMap { byID[$0] }
}

/// A sky and a horizon rather than one flat fill: a uniform bitmap is the cheapest picture ImageIO can
/// decode, and the point of this number is what a camera-sized frame costs to read and shrink.
private func writeBenchJPEG(to url: URL, width: Int, height: Int) -> Bool {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.setFillColor(CGColor(red: 0.32, green: 0.52, blue: 0.78, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    context.setFillColor(CGColor(red: 0.62, green: 0.66, blue: 0.42, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    for index in 0..<8 {
        context.setFillColor(CGColor(gray: 0.2 + Double(index) * 0.06, alpha: 1))
        context.fill(CGRect(x: index * width / 8, y: 0, width: width / 16, height: height / 4))
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
          ) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: - Measuring

private enum BenchmarkError: Error {
    case writeFailed(String)
}

private enum Bench {
    static let environment = ProcessInfo.processInfo.environment

    static let isEnabled = !(environment["GALLERY_BENCH"] ?? "").isEmpty
    static let items = positive("GALLERY_BENCH_ITEMS", fallback: 20_000)
    static let photos = positive("GALLERY_BENCH_PHOTOS", fallback: 1_000)
    static let viewport = positive("GALLERY_BENCH_VIEWPORT", fallback: 60)
    static let existingTree = environment["GALLERY_BENCH_TREE"].map { URL(fileURLWithPath: $0) }

    private static func positive(_ key: String, fallback: Int) -> Int {
        guard let raw = environment[key], let value = Int(raw), value > 0 else { return fallback }
        return value
    }

    static func note(_ line: String) { print("M3-BENCH \(line)") }
}

/// Peak `phys_footprint` while work runs.
///
/// Sampled on a timer because a high-water mark has no other observer inside the process that raised it,
/// and the number the criterion asks about is the one the kernel would kill us over — not the sum of the
/// allocations a test can name.
private actor FootprintSampler {
    private var peak: Double = 0
    private var loop: Task<Void, Never>?

    /// Takes the baseline — the process as it stands before the work — and returns it.
    @discardableResult
    func start() -> Double {
        let baseline = footprintMB()
        peak = baseline
        loop = Task.detached { [weak self] in
            while !Task.isCancelled {
                let current = footprintMB()
                await self?.absorb(current)
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return baseline
    }

    private func absorb(_ value: Double) {
        peak = max(peak, value)
    }

    func stop() -> Double {
        loop?.cancel()
        loop = nil
        peak = max(peak, footprintMB())
        return peak
    }
}

private func footprintMB() -> Double {
    var info = rusage_info_current()
    let code = withUnsafeMutablePointer(to: &info) { raw -> Int32 in
        raw.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
        }
    }
    guard code == 0 else { return .nan }
    return Double(info.ri_phys_footprint) / 1_048_576
}

/// Polls the observable rather than sleeping for a guess — the same discipline the other suites use, with a
/// longer clock because this fixture is a thousand files rather than three.
private func poll(every: Duration = .milliseconds(5), timeout: Duration = .seconds(60),
                  until condition: () async -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: every)
    }
    return await condition()
}

private extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
