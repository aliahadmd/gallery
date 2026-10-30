import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GalleryEditing
import GalleryDomain

private final class ExportScratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func folder(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func source(_ name: String, kind: MediaKind = .image, id: Int64 = 1) -> EditSource {
        EditSource(mediaID: MediaID(rawValue: id), url: file(name), kind: kind, name: name)
    }

    func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }
}

@Test func exportAppliesOrientationAndKeepsCameraMetadata() async throws {
    let scratch = try ExportScratch()
    let original = scratch.file("IMG_0001.jpg")
    let image = try #require(EditFixture.quadrantImage(width: 64, height: 48))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
            kCGImagePropertyExifSubjectArea: [100, 100, 200, 200],
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone 15",
            kCGImagePropertyTIFFOrientation: 6,
        ],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 51.5,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.12,
            kCGImagePropertyGPSLongitudeRef: "W",
        ],
    ]
    #expect(EditFixture.write(image, to: original, properties: properties))

    let exporter = Exporter()
    // `.longSide` rather than the identity recipe: this file is a byte copy if nothing changes, and the
    // point of this test is the render path.
    let result = await exporter.export(
        ExportRequest(source: scratch.source("IMG_0001.jpg"), recipe: EditRecipe(resize: .longSide(1000))),
        to: scratch.file("copy.jpg")
    )
    let url = try result.get()

    let header = try #require(EditRenderer.readHeader(url))
    #expect(header.size == PixelSize(width: 48, height: 64))
    #expect(header.orientation == 1)

    let exif = header.properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:06 07:08:09")
    #expect(exif?[kCGImagePropertyExifSubjectArea] == nil)
    let tiff = header.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Apple")
    #expect(tiff?[kCGImagePropertyTIFFModel] as? String == "iPhone 15")
    #expect(tiff?[kCGImagePropertyTIFFOrientation] == nil)
    let gps = header.properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
    #expect(number(gps?[kCGImagePropertyGPSLatitude]) == 51.5)

    let exported = try #require(EditRenderer.decode(url))
    #expect(EditFixture.matches(EditFixture.sample(exported, 0.25, 0.25), EditFixture.bottomLeft))
    #expect(EditFixture.matches(EditFixture.sample(exported, 0.75, 0.25), EditFixture.topLeft))
    #expect(EditFixture.matches(EditFixture.sample(exported, 0.25, 0.75), EditFixture.bottomRight))
    #expect(EditFixture.matches(EditFixture.sample(exported, 0.75, 0.75), EditFixture.topRight))
}

@Test func identityRecipeCopiesBytes() async throws {
    let scratch = try ExportScratch()
    let original = scratch.file("IMG_0002.jpg")
    let image = try #require(EditFixture.quadrantImage(width: 64, height: 48))
    #expect(EditFixture.write(
        image, to: original,
        properties: [kCGImagePropertyOrientation: 6,
                     kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple"]]
    ))
    let sourceData = try Data(contentsOf: original)

    let exporter = Exporter()
    let result = await exporter.export(
        ExportRequest(source: scratch.source("IMG_0002.jpg"), recipe: EditRecipe()),
        to: scratch.file("copy.jpg")
    )
    let url = try result.get()
    #expect(try Data(contentsOf: url) == sourceData)
    #expect(try #require(EditRenderer.readHeader(url)).orientation == 6)
}

@Test func cropAndResizeProduceTheRequestedPixels() async throws {
    let scratch = try ExportScratch()
    let original = scratch.file("crop.jpg")
    let image = try #require(EditFixture.quadrantImage(width: 400, height: 300))
    #expect(EditFixture.write(image, to: original))

    let recipe = EditRecipe(
        crop: CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        resize: .longSide(100)
    )
    let exporter = Exporter()
    let url = try await exporter.export(
        ExportRequest(source: scratch.source("crop.jpg"), recipe: recipe),
        to: scratch.file("cropped.png")
    ).get()

    let header = try #require(EditRenderer.readHeader(url))
    #expect(header.size == PixelSize(width: 100, height: 75))
    let exported = try #require(EditRenderer.decode(url))
    for (fx, fy) in [(0.2, 0.2), (0.5, 0.5), (0.8, 0.8)] {
        #expect(EditFixture.matches(EditFixture.sample(exported, fx, fy), EditFixture.bottomRight),
                "pixel at \(fx), \(fy)")
    }
}

@Test func exportWritesTheChosenContainer() async throws {
    let scratch = try ExportScratch()
    let original = scratch.file("format.jpg")
    let image = try #require(EditFixture.quadrantImage(width: 120, height: 80))
    #expect(EditFixture.write(image, to: original))

    var recipe = EditRecipe(crop: CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
    recipe.format = OutputFormat(kind: .png)
    let exporter = Exporter()
    let url = try await exporter.export(
        ExportRequest(source: scratch.source("format.jpg"), recipe: recipe),
        to: scratch.file("format.png")
    ).get()
    let header = try #require(EditRenderer.readHeader(url))
    #expect(header.type == UTType.png.identifier as CFString)
    #expect(OutputFormats.isWritable(.png))
}

@Test func oversizedExportsAreRefusedAndLeaveNoTemp() async throws {
    let scratch = try ExportScratch()
    let original = scratch.file("huge.jpg")
    #expect(EditFixture.write(try #require(EditFixture.quadrantImage()), to: original))

    var recipe = EditRecipe()
    recipe.resize = .exact(width: 20_000, height: 20_000, fit: .fit, allowUpscale: true)
    let exporter = Exporter()
    let destination = scratch.file("huge-copy.png")
    let result = await exporter.export(
        ExportRequest(source: scratch.source("huge.jpg"), recipe: recipe), to: destination
    )
    guard case .failure(let error) = result else {
        Issue.record("expected a refusal")
        return
    }
    #expect(error == .tooManyPixels)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!scratch.contents(of: scratch.directory).contains { $0.hasPrefix(".gallery-tmp-") })
}

@Test func batchExportReservesNamesAndSkipsCollisions() async throws {
    let scratch = try ExportScratch()
    let out = try scratch.folder("out")
    let image = try #require(EditFixture.quadrantImage(width: 64, height: 48))
    let firstFolder = try scratch.folder("a")
    let secondFolder = try scratch.folder("b")
    let first = firstFolder.appendingPathComponent("IMG.jpg")
    let second = secondFolder.appendingPathComponent("IMG.jpg")
    #expect(EditFixture.write(image, to: first))
    #expect(EditFixture.write(image, to: second))

    let requests = [
        ExportRequest(
            source: EditSource(mediaID: MediaID(rawValue: 1), url: first, name: "IMG.jpg"),
            recipe: EditRecipe()
        ),
        ExportRequest(
            source: EditSource(mediaID: MediaID(rawValue: 2), url: second, name: "IMG.jpg"),
            recipe: EditRecipe()
        ),
    ]
    let exporter = Exporter()
    let outcome = await exporter.export(requests, to: out, policy: .init(), progress: { _ in })
    #expect(outcome.failed.isEmpty)
    #expect(Set(outcome.written.map(\.lastPathComponent)) == ["IMG.jpg", "IMG-2.jpg"])
    #expect(!scratch.contents(of: out).contains { $0.hasPrefix(".gallery-tmp-") })

    let skipOutcome = await exporter.export(
        requests, to: out, policy: .init(collision: .skip), progress: { _ in }
    )
    #expect(skipOutcome.written.isEmpty)
    #expect(skipOutcome.skipped.count == 2)
}

@Test func aFailedRequestLeavesNoTempBehind() async throws {
    let scratch = try ExportScratch()
    let out = try scratch.folder("out")
    let clip = scratch.file("clip.mov")
    try Data("not a movie".utf8).write(to: clip)
    let request = ExportRequest(
        source: EditSource(mediaID: MediaID(rawValue: 9), url: clip, kind: .video, name: "clip.mov"),
        recipe: EditRecipe()
    )
    let exporter = Exporter()
    let outcome = await exporter.export([request], to: out, policy: .init(), progress: { _ in })
    #expect(outcome.failed.values.first == .notAnImage)
    #expect(outcome.written.isEmpty)
    #expect(scratch.contents(of: out).isEmpty)
}

@Test func previewMatchesTheExportComposition() async throws {
    let scratch = try ExportScratch()
    let original = scratch.file("preview.jpg")
    let image = try #require(EditFixture.quadrantImage(width: 400, height: 300))
    #expect(EditFixture.write(image, to: original))

    let previewer = EditPreviewer()
    let preview = try #require(await previewer.preview(
        for: scratch.source("preview.jpg"),
        recipe: EditRecipe(crop: CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        maxLongSide: 100
    ))
    #expect(preview.width == 100)
    #expect(preview.height == 75)
    #expect(EditFixture.matches(EditFixture.sample(preview, 0.5, 0.5), EditFixture.bottomRight))
}

@Test func headerReportsStoredSizeAndOrientation() throws {
    let scratch = try ExportScratch()
    let original = scratch.file("header.jpg")
    let image = try #require(EditFixture.quadrantImage(width: 64, height: 48))
    #expect(EditFixture.write(image, to: original, properties: [kCGImagePropertyOrientation: 8]))
    let header = try #require(EditRenderer.readHeader(original))
    #expect(header.size == PixelSize(width: 64, height: 48))
    #expect(header.orientation == 8)
    #expect(header.type == UTType.jpeg.identifier as CFString)
}

@Test func metadataPreserverDropsWhatTheEditInvalidates() {
    let source: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyPixelWidth: 4000,
        kCGImagePropertyPixelHeight: 3000,
        kCGImagePropertyColorModel: "RGB",
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
            kCGImagePropertyExifPixelXDimension: 4000,
            kCGImagePropertyExifPixelYDimension: 3000,
            kCGImagePropertyExifSubjectArea: [1, 2, 3, 4],
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFOrientation: 6,
        ],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5],
    ]
    let plan = EditPlanBuilder.plan(
        EditRecipe(crop: CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)),
        stored: PixelSize(width: 4000, height: 3000), orientation: 6
    )!
    let kept = MetadataPreserver.properties(from: source, plan: plan)
    #expect(kept[kCGImagePropertyOrientation] == nil)
    #expect(kept[kCGImagePropertyPixelWidth] == nil)
    #expect(kept[kCGImagePropertyColorModel] == nil)
    let exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:06 07:08:09")
    #expect(exif?[kCGImagePropertyExifPixelXDimension] == nil)
    #expect(exif?[kCGImagePropertyExifSubjectArea] == nil)
    let tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Apple")
    #expect(tiff?[kCGImagePropertyTIFFOrientation] == nil)
    #expect(kept[kCGImagePropertyGPSDictionary] != nil)
}

private func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    return nil
}

@Test func aReadOnlyDestinationFailsCleanlyAndLeavesNoTemp() async throws {
    let scratch = try ExportScratch()
    let image = try #require(EditFixture.quadrantImage(width: 64, height: 48))
    let sourceURL = scratch.file("a.jpg")
    #expect(EditFixture.write(image, to: sourceURL))
    let folder = try scratch.folder("locked")
    chmod(folder.path, 0o555)
    defer { chmod(folder.path, 0o755) }

    let source = scratch.source("a.jpg")
    var recipe = EditRecipe()
    recipe.format = OutputFormat(kind: .jpeg)
    let outcome = await Exporter().export(
        [ExportRequest(source: source, recipe: recipe)],
        to: folder,
        policy: .init(),
        progress: { _ in }
    )
    #expect(outcome.written.isEmpty)
    #expect(outcome.failed[source.mediaID] == .destinationNotWritable
            || outcome.failed[source.mediaID] == .encodeFailed,
            "a read-only folder is a failure, not a success at an unexpected path")
    #expect(scratch.contents(of: folder).isEmpty, "no temp file is left behind")
}
