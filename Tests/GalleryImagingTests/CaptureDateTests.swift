import Foundation
import Testing
import UniformTypeIdentifiers
@testable import GalleryImaging
import GalleryDomain

/// One temp directory per test, removed when that test's instance goes away.
final class Scratch {
    enum Failure: Error {
        case readBackFailed(URL)
        case noEncoder

        var localizedDescription: String {
            switch self {
            case .readBackFailed(let url): "ImageIO could not read back \(url.lastPathComponent)"
            case .noEncoder: "this machine has no encoder for the container the test asked for"
            }
        }
    }

    let directory: URL
    private let zone = TimeZone(secondsFromGMT: 0)!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("imaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func metadata(_ fixture: ImageFixture, name: String = "shot", type: UTType = .jpeg) throws -> FileMetadata {
        let url: URL
        do {
            url = try fixture.write(into: directory, named: filename(name, type), type: type)
        } catch ImageFixture.FixtureFailure.noEncoder {
            throw Failure.noEncoder
        }
        return try read(url)
    }

    /// The whole path: encode a real file, decode it with ImageIO, run the ladder. `mtime` is stamped onto
    /// the file so the last rung of the ladder has something honest to fall back to.
    func capture(_ fixture: ImageFixture, mtime: Date? = nil, name: String = "shot",
                 type: UTType = .jpeg, assumedZone: TimeZone) throws -> CaptureMoment? {
        let url = try fixture.write(into: directory, named: filename(name, type), type: type)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return CaptureDateResolver.resolve(dates: try read(url).dates, modificationDate: mtime,
                                           assumedZone: assumedZone)
    }

    private func read(_ url: URL) throws -> FileMetadata {
        guard case .decoded(let metadata) = ImageMetadataReader.read(at: url) else {
            throw Failure.readBackFailed(url)
        }
        return metadata
    }

    private func filename(_ base: String, _ type: UTType) -> String {
        "\(base).\(type.preferredFilenameExtension ?? "jpg")"
    }

    /// A file with bytes of the test's choosing — the failure paths need damaged input, not damaged
    /// metadata.
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Writes a date as a file would carry one, so a test says the moment it means rather than a magic
    /// number of seconds.
    func wallClock(_ text: String) -> Date {
        guard let date = CaptureDateResolver.parseWallClock(text) else {
            Issue.record("not a wall clock the resolver can read: \(text)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    func utc(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = zone
        guard let date = formatter.date(from: text) else {
            Issue.record("not an instant: \(text)")
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }
}

@Suite("Capture date ladder")
struct CaptureDateTests {
    let scratch: Scratch
    private static let tokyo = TimeZone(secondsFromGMT: 9 * 3600)!
    private static let kathmandu = TimeZone(secondsFromGMT: 5 * 3600 + 45 * 60)!
    private static let newYork = TimeZone(secondsFromGMT: -5 * 3600)!

    init() throws {
        scratch = try Scratch()
    }

    // MARK: - The rung that knows its zone

    @Test("OffsetTimeOriginal gives the instant and the day in the camera's own zone")
    func offsetTimeOriginal() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 14:22:01"
        fixture.subsecTimeOriginal = "123456"
        fixture.offsetTimeOriginal = "+09:00"

        let moment = try #require(try scratch.capture(fixture, assumedZone: Self.newYork))
        // 14:22:01.123456 +09:00 is 05:22:01.123456 UTC, and the fraction has to survive with it.
        let expected = scratch.utc("2024-05-03 05:22:01 +0000").addingTimeInterval(0.123456)
        #expect(abs(moment.instant.timeIntervalSince(expected)) < 0.001)
        #expect(moment.source == .exifOffsetTimeOriginal)
        #expect(moment.timeZone?.secondsFromGMT() == 9 * 3600)
        #expect(moment.dayBucket == 20240503)
        // The viewer's own zone must not move the bucket: this is a travel photo, not a local one.
        #expect(moment.monthBucket == 202405)
    }

    @Test("A half-hour zone offset survives the round trip")
    func kathmanduOffset() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:01:15 09:30:00"
        fixture.offsetTimeOriginal = "+05:45"

        let moment = try #require(try scratch.capture(fixture, assumedZone: Self.tokyo))
        #expect(abs(moment.instant.timeIntervalSince(scratch.utc("2024-01-15 03:45:00 +0000"))) < 0.001)
        #expect(moment.dayBucket == 20240115)
    }

    @Test("An offset written without minutes, and one written as Zulu, still place the instant")
    func offsetShapes() throws {
        // ImageIO's own encoder refuses both of these shapes — a fixture written here comes back with no
        // offset at all — so the ladder is tested against the values rather than the container. Files from
        // ExifTool, Lightroom and a few compacts do carry them.
        let wall = "2024:05:03 14:22:01"
        let hours = try #require(CaptureDateResolver.resolve(
            dates: ExifDates(dateTimeOriginal: wall, offsetTimeOriginal: "+09"),
            modificationDate: nil, assumedZone: Self.newYork))
        #expect(hours.source == .exifOffsetTimeOriginal)
        #expect(abs(hours.instant.timeIntervalSince(scratch.utc("2024-05-03 05:22:01 +0000"))) < 0.001)
        #expect(hours.dayBucket == 20240503)

        let zulu = try #require(CaptureDateResolver.resolve(
            dates: ExifDates(dateTimeOriginal: wall, offsetTimeOriginal: "Z"),
            modificationDate: nil, assumedZone: Self.newYork))
        #expect(abs(zulu.instant.timeIntervalSince(scratch.utc("2024-05-03 14:22:01 +0000"))) < 0.001)
        // "Z" is UTC, so the bucket is a UTC day even though the viewer is in New York.
        #expect(zulu.dayBucket == 20240503)

        // And what the encoder really does with them: nothing. The naive rung has to be honest about the
        // zone it guessed rather than pretend the file said.
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = wall
        fixture.offsetTimeOriginal = "Z"
        let roundTripped = try #require(try scratch.capture(fixture, name: "zulu-file",
                                                           assumedZone: Self.newYork))
        #expect(roundTripped.source == .exifDateTimeOriginal)
        #expect(abs(roundTripped.instant.timeIntervalSince(
            scratch.utc("2024-05-03 19:22:01 +0000"))) < 1)
    }

    @Test("A negative offset crosses into the next UTC day and still buckets locally")
    func negativeOffsetAcrossMidnight() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 21:30:00"
        fixture.offsetTimeOriginal = "-05:00"

        let moment = try #require(try scratch.capture(fixture, assumedZone: Self.tokyo))
        #expect(abs(moment.instant.timeIntervalSince(scratch.utc("2024-05-04 02:30:00 +0000"))) < 0.001)
        #expect(moment.dayBucket == 20240503)
    }

    // MARK: - The rungs that guess

    @Test("A bare DateTimeOriginal is bucketed in the assumed zone, not shifted by it twice")
    func dateTimeOriginalWithoutOffset() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 20:00:00"

        let moment = try #require(try scratch.capture(fixture, assumedZone: Self.tokyo))
        #expect(moment.source == .exifDateTimeOriginal)
        // The bug this guards: treating the naive reading as UTC and then bucketing it in Tokyo puts the
        // photo in tomorrow's album.
        #expect(moment.dayBucket == 20240503)
        #expect(abs(moment.instant.timeIntervalSince(scratch.utc("2024-05-03 11:00:00 +0000"))) < 1)
    }

    @Test("The same naive reading buckets the same way whichever machine reads it")
    func naiveReadingIsZoneIndependent() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 20:00:00"

        let inTokyo = try #require(try scratch.capture(fixture, name: "tokyo", assumedZone: Self.tokyo))
        let inNewYork = try #require(try scratch.capture(fixture, name: "york", assumedZone: Self.newYork))
        #expect(inTokyo.dayBucket == inNewYork.dayBucket)
        #expect(inTokyo.instant != inNewYork.instant)
    }

    @Test("DateTimeDigitized is the next rung down, and keeps its own offset")
    func dateTimeDigitized() throws {
        var fixture = ImageFixture()
        fixture.dateTimeDigitized = "2023:11:02 08:15:00"
        fixture.offsetTimeDigitized = "-05:00"

        let moment = try #require(try scratch.capture(fixture, assumedZone: Self.tokyo))
        #expect(moment.source == .exifDateTimeDigitized)
        #expect(abs(moment.instant.timeIntervalSince(scratch.utc("2023-11-02 13:15:00 +0000"))) < 0.001)
        #expect(moment.dayBucket == 20231102)
    }

    @Test("Original outranks digitized when a camera writes both")
    func originalBeatsDigitized() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 14:22:01"
        fixture.offsetTimeOriginal = "+09:00"
        fixture.dateTimeDigitized = "2025:01:01 00:00:00"

        let moment = try #require(try scratch.capture(fixture, assumedZone: Self.newYork))
        #expect(moment.source == .exifOffsetTimeOriginal)
        #expect(moment.dayBucket == 20240503)
    }

    @Test("A TIFF DateTime with no Exif date still lands a rung above the filesystem")
    func tiffDateTimeOnly() throws {
        var fixture = ImageFixture()
        fixture.tiffDateTime = "2022:07:04 18:30:00"

        // A scanner or an editor that writes only the TIFF field is common, and HEIC is where the field
        // survives: JPEG's encoder rebuilds its TIFF directory and drops a supplied DateTime, so the same
        // fixture written as a JPEG honestly falls through to the file date.
        let moment = try #require(try scratch.capture(fixture, mtime: scratch.utc("2024-01-01 00:00:00 +0000"),
                                                      name: "tiff-only", type: .heic,
                                                      assumedZone: Self.newYork))
        #expect(moment.source == .exifDateTimeDigitized)
        #expect(moment.dayBucket == 20220704)

        let asJPEG = try #require(try scratch.capture(fixture, mtime: scratch.utc("2024-01-01 00:00:00 +0000"),
                                                       name: "tiff-only-jpeg", assumedZone: Self.newYork))
        #expect(asJPEG.source == .fileSystem)
    }

    // MARK: - The last rungs

    @Test("No Exif date at all falls back to the file's own modification date")
    func fileSystemFallback() throws {
        let mtime = scratch.utc("2021-03-04 05:06:07 +0000")
        let moment = try #require(try scratch.capture(ImageFixture(), mtime: mtime, name: "bare",
                                                     assumedZone: Self.newYork))
        #expect(moment.source == .fileSystem)
        #expect(abs(moment.instant.timeIntervalSince(mtime)) < 1)
    }

    @Test("Nothing to go on is reported as unknown rather than invented")
    func nothingAtAll() throws {
        let moment = try scratch.capture(ImageFixture(), mtime: nil, name: "empty-dates",
                                        assumedZone: Self.newYork)
        #expect(moment == nil)
    }

    @Test("An asset creation date outranks the filesystem and is already an instant")
    func assetCreationDate() {
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let moment = CaptureDateResolver.resolve(
            dates: ExifDates(assetCreationDate: created),
            modificationDate: Date(timeIntervalSince1970: 1),
            assumedZone: Self.tokyo
        )
        #expect(moment?.source == .assetCreationDate)
        #expect(moment?.instant == created)
    }

    // MARK: - Readings that cannot be true

    @Test("A zeroed-out Exif date is treated as no date")
    func zeroedDate() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "0000:00:00 00:00:00"

        let moment = try #require(try scratch.capture(fixture, mtime: scratch.utc("2020-02-02 02:02:02 +0000"),
                                                     name: "zeroed", assumedZone: Self.newYork))
        #expect(moment.source == .fileSystem)
    }

    @Test("A dead clock battery's 1904 or 2040 stamp does not outrank the file")
    func absurdYears() throws {
        var old = ImageFixture()
        old.dateTimeOriginal = "1904:01:01 00:00:00"
        let before = try #require(try scratch.capture(old, mtime: scratch.utc("2019-09-09 09:09:09 +0000"),
                                                     name: "1904", assumedZone: Self.newYork))
        #expect(before.source == .fileSystem)

        var future = ImageFixture()
        future.dateTimeOriginal = "2105:01:01 00:00:00"
        let after = try #require(try scratch.capture(future, mtime: scratch.utc("2019-09-09 09:09:09 +0000"),
                                                    name: "2105", assumedZone: Self.newYork))
        #expect(after.source == .fileSystem)
    }

    @Test("A film photo from 1995 is old, not invalid")
    func preY2000IsSane() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "1995:06:18 12:00:00"

        let moment = try #require(try scratch.capture(fixture, mtime: scratch.utc("2024-01-01 00:00:00 +0000"),
                                                     name: "1995", assumedZone: Self.newYork))
        #expect(moment.source == .exifDateTimeOriginal)
        #expect(moment.dayBucket == 19950618)
    }

    // MARK: - Ordering inside a second

    @Test("Subsecond precision keeps burst frames in the order the camera shot them")
    func subsecondOrdering() throws {
        var first = ImageFixture()
        first.dateTimeOriginal = "2024:05:03 14:22:01"
        first.subsecTimeOriginal = "250"
        var second = ImageFixture()
        second.dateTimeOriginal = "2024:05:03 14:22:01"
        second.subsecTimeOriginal = "750"

        let a = try #require(try scratch.capture(first, name: "burst-a", assumedZone: Self.tokyo))
        let b = try #require(try scratch.capture(second, name: "burst-b", assumedZone: Self.tokyo))
        #expect(abs(b.instant.timeIntervalSince(a.instant) - 0.5) < 0.001)
    }

    @Test("A subsecond written with its leading dot reads the same as one without")
    func subsecondShapes() throws {
        var dotted = ImageFixture()
        dotted.dateTimeOriginal = "2024:05:03 14:22:01"
        dotted.subsecTimeOriginal = ".500"
        var plain = ImageFixture()
        plain.dateTimeOriginal = "2024:05:03 14:22:01"
        plain.subsecTimeOriginal = "500"

        let one = try #require(try scratch.capture(dotted, name: "dotted", assumedZone: Self.tokyo))
        let two = try #require(try scratch.capture(plain, name: "plain", assumedZone: Self.tokyo))
        #expect(abs(one.instant.timeIntervalSince(two.instant)) < 0.001)
    }

    // MARK: - Containers

    @Test("HEIC carries the same ladder answer as JPEG")
    func heicRoundTrip() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 14:22:01"
        fixture.offsetTimeOriginal = "+09:00"

        let moment = try #require(try scratch.capture(fixture, type: .heic, assumedZone: Self.newYork))
        #expect(moment.source == .exifOffsetTimeOriginal)
        #expect(moment.dayBucket == 20240503)
        #expect(abs(moment.instant.timeIntervalSince(scratch.utc("2024-05-03 05:22:01 +0000"))) < 0.001)
    }

    @Test("A PNG is dated from its Exif block when it has one and from its file date when it does not")
    func pngRoundTrip() throws {
        let mtime = scratch.utc("2020-01-02 03:04:05 +0000")
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 14:22:01"

        // PNG's `eXIf` chunk is younger than the format, but ImageIO writes it — which matters because the
        // files users keep as PNG are the ones they edited, and an editor is exactly what preserves a date.
        let dated = try #require(try scratch.capture(fixture, mtime: mtime, name: "png", type: .png,
                                                    assumedZone: Self.newYork))
        #expect(dated.source == .exifDateTimeOriginal)
        #expect(dated.dayBucket == 20240503)

        // A screenshot's PNG carries no Exif at all, and the file date is the only honest answer.
        let bare = try #require(try scratch.capture(ImageFixture(), mtime: mtime, name: "png-bare",
                                                   type: .png, assumedZone: Self.newYork))
        #expect(bare.source == .fileSystem)
    }

    // MARK: - Parsing, without a file in sight

    @Test("Offsets are read in the shapes cameras actually write")
    func offsetShapesParsed() {
        #expect(CaptureDateResolver.parseOffset("+09:00") == 9 * 3600)
        #expect(CaptureDateResolver.parseOffset("-05:30") == -(5 * 3600 + 30 * 60))
        #expect(CaptureDateResolver.parseOffset("+0545") == 5 * 3600 + 45 * 60)
        #expect(CaptureDateResolver.parseOffset("+09") == 9 * 3600)
        #expect(CaptureDateResolver.parseOffset("Z") == 0)
        #expect(CaptureDateResolver.parseOffset("") == nil)
        #expect(CaptureDateResolver.parseOffset(nil) == nil)
        // Not an offset: a camera that wrote the time here would shift every photo it owns.
        #expect(CaptureDateResolver.parseOffset("09:00") == nil)
        #expect(CaptureDateResolver.parseOffset("+9 hours") == nil)
    }

    @Test("Wall clocks parse in the separators cameras actually use")
    func wallClockShapesParsed() {
        let expected = Date(timeIntervalSince1970: 1_714_746_121)  // 2024-05-03 14:22:01 as UTC
        for text in ["2024:05:03 14:22:01", "2024-05-03 14:22:01", "2024:05:03T14:22:01",
                     "2024:05:03 14:22:01Z", "2024:05:03_14:22:01"] {
            #expect(abs((CaptureDateResolver.parseWallClock(text) ?? .distantPast)
                        .timeIntervalSince(expected)) < 1, "parsed \(text)")
        }
        #expect(CaptureDateResolver.parseWallClock("May 3, 2024") == nil)
        #expect(CaptureDateResolver.parseWallClock("") == nil)
    }

    @Test("A day bucket is computed in the capture zone, not the machine's")
    func bucketsFollowTheCaptureZone() throws {
        var fixture = ImageFixture()
        fixture.dateTimeOriginal = "2024:05:03 23:30:00"
        fixture.offsetTimeOriginal = "+09:00"

        let moment = try #require(try scratch.capture(fixture, name: "latenight", assumedZone: Self.newYork))
        #expect(moment.dayBucket == 20240503)
        // UTC-wise it is still the 3rd at 14:30, and New York-wise it is the 3rd too; the point is that no
        // viewer zone can move it to the 4th.
        #expect(CaptureMoment.dayBucket(of: moment.instant, timeZone: Self.newYork) == 20240503)
    }
}
