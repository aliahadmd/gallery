import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GalleryEditing
import GalleryDomain

@Test func collagePlacesEachMemberInItsSlot() async throws {
    let scratch = try CollageScratch()
    let colours: [(String, RGBAColor)] = [
        ("red", RGBAColor(red: 0.9, green: 0.1, blue: 0.1)),
        ("green", RGBAColor(red: 0.1, green: 0.8, blue: 0.2)),
        ("blue", RGBAColor(red: 0.1, green: 0.2, blue: 0.9)),
        ("yellow", RGBAColor(red: 0.95, green: 0.9, blue: 0.1)),
    ]
    var members: [MediaID: EditSource] = [:]
    var ids: [MediaID] = []
    var sizes: [MediaID: Int] = [:]
    for (index, entry) in colours.enumerated() {
        let id = MediaID(rawValue: Int64(index + 1))
        let url = scratch.file("\(entry.0).png")
        try solidColour(entry.1).write(to: url)
        members[id] = EditSource(mediaID: id, url: url, name: "\(entry.0).png")
        ids.append(id)
        sizes[id] = 200
    }

    let document = CollageDocument(
        memberIDs: ids, template: .grid(columns: 2), aspect: .square,
        longSide: 1000, gutterFraction: 0, marginFraction: 0, background: .white
    )
    let composer = CollageComposer()
    let image = try #require(await composer.render(document, members: members, sourceLongSides: sizes))
    #expect(image.width == 1000 && image.height == 1000)
    #expect(EditFixture.matches(EditFixture.sample(image, 0.25, 0.25), colours[0].1))
    #expect(EditFixture.matches(EditFixture.sample(image, 0.75, 0.25), colours[1].1))
    #expect(EditFixture.matches(EditFixture.sample(image, 0.25, 0.75), colours[2].1))
    #expect(EditFixture.matches(EditFixture.sample(image, 0.75, 0.75), colours[3].1))
}

@Test func missingMemberBecomesAPlaceholderNotAHole() async throws {
    let id = MediaID(rawValue: 1)
    let document = CollageDocument(
        memberIDs: [id, MediaID(rawValue: 2)], template: .grid(columns: 2), aspect: .square,
        longSide: 800, gutterFraction: 0, marginFraction: 0, background: .black
    )
    let composer = CollageComposer()
    let image = try #require(await composer.render(document, members: [:], sourceLongSides: [:]))
    // Both slots are placeholders on a black background: neither may stay pure black.
    let left = EditFixture.sample(image, 0.25, 0.5)
    let right = EditFixture.sample(image, 0.75, 0.5)
    #expect(!(left.red < 0.02 && left.green < 0.02 && left.blue < 0.02))
    #expect(!(right.red < 0.02 && right.green < 0.02 && right.blue < 0.02))
}

@Test func collageTitleDrawsInTheBand() async throws {
    let id = MediaID(rawValue: 1)
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t-\(UUID()).png")
    try solidColour(RGBAColor(red: 0.2, green: 0.4, blue: 0.6)).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = CollageDocument(
        memberIDs: [id], template: .grid(columns: 1), aspect: .square,
        longSide: 800, gutterFraction: 0.01, marginFraction: 0.03,
        background: .white, title: "SUMMER"
    )
    let composer = CollageComposer()
    let image = try #require(await composer.render(
        document,
        members: [id: EditSource(mediaID: id, url: url, name: "a.png")],
        sourceLongSides: [id: 400]
    ))
    let layout = CollageLayoutEngine.layout(document, sourceLongSides: [id: 400])
    let title = try #require(layout.titleFrame)
    #expect(inkCount(image, in: title, threshold: 0.2) > 20, "the title band should carry dark glyphs")
}

@Test func collageExportsAFile() async throws {
    let scratch = try CollageScratch()
    let id = MediaID(rawValue: 1)
    let memberURL = scratch.file("member.png")
    try solidColour(RGBAColor(red: 0.8, green: 0.2, blue: 0.2)).write(to: memberURL)
    let document = CollageDocument(
        memberIDs: [id], template: .grid(columns: 1), aspect: .landscape3x2,
        longSide: 900, gutterFraction: 0, marginFraction: 0, background: .black
    )
    let destination = scratch.file("collage.png")
    let composer = CollageComposer()
    let written = await composer.write(
        document,
        members: [id: EditSource(mediaID: id, url: memberURL, name: "member.png")],
        sourceLongSides: [id: 200],
        to: destination
    )
    #expect(written)
    let header = try #require(EditRenderer.readHeader(destination))
    #expect(header.size == PixelSize(width: 900, height: 600))
}

private func solidColour(_ colour: RGBAColor) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(ImageDraw.cgColor(colour))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private final class CollageScratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("collage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}
