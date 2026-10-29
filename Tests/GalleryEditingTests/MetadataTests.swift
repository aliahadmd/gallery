import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GalleryEditing
import GalleryDomain
import GalleryImaging

@Test func exifOffsetRoundTripsThroughTheResolver() {
    #expect(ExifOffset.format(0) == "Z")
    #expect(ExifOffset.format(9 * 3600) == "+09:00")
    #expect(ExifOffset.format(-(5 * 3600 + 30 * 60)) == "-05:30")
    for seconds in [0, 32400, -19800, 19800, -3600, 12 * 3600] {
        #expect(CaptureDateResolver.parseOffset(ExifOffset.format(seconds)) == seconds,
                "\(ExifOffset.format(seconds)) should parse back to \(seconds)")
    }
    #expect(CaptureDateResolver.parseOffset("+09") == 32400)
}

@Test func overridesResolveIntoValues() {
    let existing = ExistingMetadata(
        title: "Old", captureInstant: Date(timeIntervalSince1970: 1_700_000_000),
        offsetSeconds: 32400, gps: GPSPoint(latitude: 1, longitude: 2)
    )
    #expect(MetadataValues.resolve(MetadataOverrides(), existing: existing).title == "Old")

    var clear = MetadataOverrides(title: .clear, capture: .clear, gps: .clear)
    let cleared = MetadataValues.resolve(clear, existing: existing)
    #expect(cleared.title == nil && cleared.capture == nil && cleared.gps == nil)

    clear.title = .set("  New title  ")
    #expect(MetadataValues.resolve(clear, existing: existing).title == "New title")
    clear.title = .set("   ")
    #expect(MetadataValues.resolve(clear, existing: existing).title == nil,
            "whitespace is not a title")
}

@Test func metadataRewriteWritesTitleDateAndLocation() throws {
    let scratch = try MetadataScratch()
    let original = scratch.file("shot.jpg")
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
            kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
            kCGImagePropertyExifLensModel: "24-70mm",
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Canon",
            kCGImagePropertyTIFFModel: "EOS R5",
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 48.85,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.35,
            kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]
    let image = try #require(EditFixture.quadrantImage(width: 200, height: 150))
    #expect(EditFixture.write(image, to: original, properties: properties))
    let pixelsBefore = pixels(try #require(EditRenderer.decode(original)))
    let before = try #require(MetadataEditor.readBack(original))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 32400)!
    let newDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
    let overrides = MetadataOverrides(
        title: .set("Kyoto at dusk"),
        capture: .set(CaptureEdit(instant: newDate, offsetSeconds: 32400)),
        gps: .set(GPSPoint(latitude: 35.01, longitude: 135.76, altitude: 42))
    )
    let destination = scratch.file("edited.jpg")
    let result = MetadataEditor.rewrite(original, overrides: overrides, existing: before, to: destination)
    guard case .written(let reencoded) = result else {
        Issue.record("rewrite failed: \(result)")
        return
    }
    #expect(!reencoded, "a JPEG must be edited by copying its compressed data, not by re-encoding")

    let after = try #require(MetadataEditor.readBack(destination))
    #expect(after.title == "Kyoto at dusk")
    #expect(after.captureInstant != nil && abs(after.captureInstant!.timeIntervalSince(newDate)) < 1)
    #expect(after.offsetSeconds == 32400)
    #expect(after.gps != nil && abs(after.gps!.latitude - 35.01) < 1e-4
        && abs(after.gps!.longitude - 135.76) < 1e-4)
    #expect(after.gps?.altitude != nil && abs(after.gps!.altitude! - 42) < 1e-3)

    // The pixels are byte-identically the same picture, which is the proof no re-encode happened.
    let pixelsAfter = pixels(try #require(EditRenderer.decode(destination)))
    #expect(pixelsBefore == pixelsAfter)

    // Everything the edit did not name is still there.
    let header = try #require(EditRenderer.readHeader(destination))
    let tiff = header.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Canon")
    #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "EOS R5")
    let exif = header.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifLensModel] as? String == "24-70mm")
}

@Test func metadataRewriteCanClearFields() throws {
    let scratch = try MetadataScratch()
    let original = scratch.file("clear.jpg")
    let properties: [CFString: Any] = [
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: "Old title"],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 48.85,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.35,
            kCGImagePropertyGPSLongitudeRef: "E",
        ],
    ]
    #expect(EditFixture.write(
        try #require(EditFixture.quadrantImage(width: 120, height: 90)),
        to: original, properties: properties
    ))
    let before = try #require(MetadataEditor.readBack(original))
    #expect(before.title == "Old title")
    #expect(before.gps != nil)

    let destination = scratch.file("cleared.jpg")
    let overrides = MetadataOverrides(title: .clear, gps: .clear)
    let result = MetadataEditor.rewrite(original, overrides: overrides, existing: before, to: destination)
    guard case .written = result else {
        Issue.record("rewrite failed: \(result)")
        return
    }
    let after = try #require(MetadataEditor.readBack(destination))
    #expect(after.title == nil)
    #expect(after.gps == nil)
}

@Test func aTitleOnlyEditLeavesTheCaptureDateAlone() throws {
    let scratch = try MetadataScratch()
    let original = scratch.file("date.jpg")
    #expect(EditFixture.write(
        try #require(EditFixture.quadrantImage(width: 120, height: 90)), to: original,
        properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2021:11:12 13:14:15",
                kCGImagePropertyExifOffsetTimeOriginal: "-05:00",
            ],
        ]
    ))
    let before = try #require(MetadataEditor.readBack(original))
    let destination = scratch.file("titled.jpg")
    let result = MetadataEditor.rewrite(
        original, overrides: MetadataOverrides(title: .set("Hello")), existing: before, to: destination
    )
    guard case .written = result else {
        Issue.record("rewrite failed: \(result)")
        return
    }
    let after = try #require(MetadataEditor.readBack(destination))
    #expect(after.title == "Hello")
    #expect(after.offsetSeconds == -18000)
    #expect(after.captureInstant == before.captureInstant)
}

private final class MetadataScratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}
