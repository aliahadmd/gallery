import Foundation
import AVFoundation
import CoreGraphics
import Testing
import UniformTypeIdentifiers
@testable import GalleryImaging
import GalleryDomain

@Suite("Metadata readers")
struct MetadataReaderTests {
    let scratch: Scratch

    init() throws {
        scratch = try Scratch()
    }

    // MARK: - Stills

    @Test("A JPEG header gives the grid everything it lays out with")
    func stillProperties() throws {
        var fixture = ImageFixture()
        fixture.width = 640
        fixture.height = 480
        fixture.orientation = 6
        fixture.dpiWidth = 144
        fixture.make = "CameraCo"
        fixture.model = "Fixture 9"
        fixture.lensModel = "35mm f/1.4"
        fixture.profileName = "sRGB IEC61966-2.1"

        let metadata = try scratch.metadata(fixture)
        #expect(metadata.typeIdentifier == "public.jpeg")
        #expect(metadata.pixelSize == PixelSize(width: 640, height: 480))
        #expect(metadata.orientation == 6)
        #expect(metadata.colorSpace == "sRGB IEC61966-2.1")
        // The screenshot heuristic's first clue: a camera file says 72, a macOS capture says 144.
        #expect(metadata.dpiWidth == 144)
        #expect(metadata.device == "CameraCo Fixture 9")
        #expect(metadata.lens == "35mm f/1.4")
        #expect(metadata.frameCount == 1)
        #expect(metadata.isRaw == false)
    }

    @Test("Orientation 6 means the stored raster is sideways, which the cell aspect ratio has to know")
    func orientationDrivesAspectRatio() throws {
        var fixture = ImageFixture()
        fixture.width = 640
        fixture.height = 480
        fixture.orientation = 6
        let metadata = try scratch.metadata(fixture, name: "sideways")

        var item = MediaItem(id: MediaID(rawValue: 1),
                             identity: FileIdentity(volumeID: "v", documentID: nil, resourceID: nil,
                                                    statHash: 0),
                             sourceID: SourceID(rawValue: 1),
                             relativePath: "sideways.jpg",
                             parentDirectory: "",
                             name: "sideways.jpg",
                             fileExtension: "jpg",
                             kind: .image,
                             uniformTypeIdentifier: "public.jpeg",
                             pixelSize: metadata.pixelSize)
        #expect(item.displayAspectRatio > 1)
        item.orientation = metadata.orientation
        #expect(abs(item.displayAspectRatio - 480.0 / 640.0) < 0.001)
    }

    @Test("GPS comes back in decimal degrees with the hemisphere references applied")
    func gpsRoundTrip() throws {
        var fixture = ImageFixture()
        fixture.latitude = 33.87
        fixture.latitudeReference = "S"
        fixture.longitude = 151.21
        fixture.longitudeReference = "W"
        fixture.altitude = 42.5
        fixture.altitudeReference = 1
        fixture.speedKilometersPerHour = 3.6
        fixture.gpsDateStamp = "2024:05:03"
        fixture.gpsTimeStamp = "05:22:01"

        let point = try #require(try scratch.metadata(fixture, name: "sydney").gps)
        #expect(abs(point.latitude + 33.87) < 0.01)
        #expect(abs(point.longitude + 151.21) < 0.01)
        #expect(point.altitude.map { abs($0 + 42.5) < 0.01 } ?? false)
        #expect(point.speedMetersPerSecond.map { abs($0 - 1.0) < 0.01 } ?? false)
        #expect(point.isValid)
        #expect(point.timestamp.map { abs($0.timeIntervalSince1970 - 1_714_713_721) < 1 } ?? false)
    }

    @Test("A fix at null island is no fix at all")
    func gpsNullIsland() throws {
        var fixture = ImageFixture()
        fixture.latitude = 0
        fixture.latitudeReference = "N"
        fixture.longitude = 0
        fixture.longitudeReference = "E"
        #expect(try scratch.metadata(fixture, name: "island").gps == nil)
    }

    @Test("An animated GIF is counted by frame, which is what makes it not a still")
    func animatedFrames() throws {
        var fixture = ImageFixture()
        fixture.frames = 3
        let metadata = try scratch.metadata(fixture, name: "wave", type: .gif)
        #expect(metadata.frameCount == 3)
    }

    // MARK: - Files that will not read

    @Test("A file that is gone by the time pass B reaches it is reported as vanished")
    func vanished() {
        let missing = scratch.url("never-existed.jpg")
        #expect(ImageMetadataReader.read(at: missing) == .failed(.vanished))
    }

    @Test("Garbage bytes in a camera's wrapper are damage, not an unsupported format")
    func corrupt() throws {
        let stub = try scratch.file("broken.cr2", Data("not a raw file at all".utf8))
        #expect(ImageMetadataReader.read(at: stub) == .failed(.corrupt))

        let empty = try scratch.file("empty.jpg", Data())
        #expect(ImageMetadataReader.read(at: empty) == .failed(.corrupt))
    }

    @Test("A file the sandbox cannot read says so instead of looking empty")
    func noAccess() throws {
        let locked = try scratch.file("locked.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9]))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        #expect(ImageMetadataReader.read(at: locked) == .failed(.noAccess))
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
    }

    // MARK: - Moving images

    @Test("A real clip reports its duration, codec and displayed size")
    func clip() async throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try await MovieFixture.write(into: scratch.directory, named: "clip.mov",
                                               seconds: 1, creationDate: created)
        guard case .decoded(let metadata) = await VideoMetadataReader.read(at: url) else {
            Issue.record("AVFoundation refused the clip this test wrote")
            return
        }
        let microseconds = try #require(metadata.durationMicroseconds)
        #expect((900_000...1_200_000).contains(microseconds))
        #expect(metadata.pixelSize == PixelSize(width: 320, height: 240))
        #expect(metadata.codec == "avc1")
        #expect(metadata.dates.assetCreationDate.map { abs($0.timeIntervalSince(created)) < 2 } ?? false)
    }

    @Test("A clip AVFoundation will not open keeps its row and carries the reason")
    func unreadableClip() async throws {
        let stub = try scratch.file("not-a-movie.mov", Data("mpeg-4 what".utf8))
        #expect(await VideoMetadataReader.read(at: stub) == .failed(.unreadableVideo))
        #expect(await VideoMetadataReader.read(at: scratch.url("gone.mov")) == .failed(.vanished))
    }

    @Test("A portrait clip's transform is folded into the size the grid lays out")
    func displayedSizeFollowsTheTransform() {
        let landscape = CGSize(width: 1920, height: 1080)
        let quarterTurn = CGAffineTransform.identity.rotated(by: .pi / 2)
        let flippedTwoTimes = CGAffineTransform.identity.scaledBy(x: 2, y: -2)

        #expect(VideoMetadataReader.displaySize(naturalSize: landscape, transform: .identity)
                == PixelSize(width: 1920, height: 1080))
        #expect(VideoMetadataReader.displaySize(naturalSize: landscape, transform: quarterTurn)
                == PixelSize(width: 1080, height: 1920))
        #expect(VideoMetadataReader.displaySize(naturalSize: landscape, transform: flippedTwoTimes)
                == PixelSize(width: 3840, height: 2160))
        #expect(VideoMetadataReader.displaySize(naturalSize: .zero, transform: .identity) == nil)
    }

    @Test("A four-character codec code reads as the string MediaInfo would show")
    func codecNames() {
        #expect(VideoMetadataReader.fourCC(0x61766331) == "avc1")
        #expect(VideoMetadataReader.fourCC(0x68766378) == "hvcx")
    }

    @Test("A non-finite duration is no duration")
    func durations() {
        #expect(VideoMetadataReader.microseconds(of: .indefinite) == nil)
        #expect(VideoMetadataReader.microseconds(of: .zero) == nil)
        #expect(VideoMetadataReader.microseconds(of: CMTime(value: 3, timescale: 2)) == 1_500_000)
    }
}
