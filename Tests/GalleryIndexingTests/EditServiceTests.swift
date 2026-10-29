import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GalleryIndexing
@testable import GalleryCatalog
import GalleryDomain
import GalleryEditing
import GallerySupport

@Test func selfWriteWindowIgnoresOurOwnWrite() {
    let guardWindow = SelfWriteGuard(duration: 5)
    let now = Date()
    #expect(!guardWindow.shouldIgnore(at: now))
    guardWindow.note(at: now)
    #expect(guardWindow.shouldIgnore(at: now.addingTimeInterval(1)))
    #expect(!guardWindow.shouldIgnore(at: now.addingTimeInterval(6)))
    #expect(!guardWindow.shouldIgnore(at: now.addingTimeInterval(-30)),
            "a clock jump backwards must not silence the watcher")
}

@Test func replaceKeepsTheInodeAndLeavesARestorableBackup() async throws {
    let fixture = try await ReplaceFixture()
    defer { fixture.tearDown() }

    let before = try FileStat.read(fixture.url)
    let xattrName = "user.gallery.test"
    let xattrValue = Data("kept".utf8)
    let wrote = xattrValue.withUnsafeBytes {
        setxattr(fixture.url.path, xattrName, $0.baseAddress, $0.count, 0, 0)
    }
    try #require(wrote == 0)
    try await fixture.catalog.setFavorite(fixture.item.id, true)
    let originalBytes = try Data(contentsOf: fixture.url)

    var recipe = EditRecipe(crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
    recipe.format = OutputFormat(kind: .jpeg)
    let outcome = await fixture.editor.replaceOriginal(fixture.item, recipe: recipe)
    #expect(outcome.replaced, "\(outcome.message ?? "")")

    let after = try FileStat.read(fixture.url)
    #expect(after.inode == before.inode, "an in-place replace must keep the inode")
    #expect(try Data(contentsOf: fixture.url) != originalBytes)
    #expect(after.modificationDate > before.modificationDate)

    var buffer = [UInt8](repeating: 0, count: 32)
    let readBack = getxattr(fixture.url.path, xattrName, &buffer, 32, 0, 0)
    #expect(readBack == xattrValue.count, "Finder tags survive a replace")
    #expect(Data(buffer.prefix(max(0, readBack))) == xattrValue)

    let row = try #require(await fixture.reader.item(id: fixture.item.id))
    #expect(row.isFavorite)
    #expect(row.trash == .live)
    #expect(row.stage == .classified, "new pixels go back through pass B")
    #expect(row.identity.statHash == after.statHash)
    #expect(try await fixture.catalog.queuedWorkCount() == 1)

    let backup = try #require(try await fixture.catalog.latestBackup(mediaID: fixture.item.id))
    #expect(backup.mode == .editBackup)
    #expect(backup.state == .backup)
    #expect(backup.completedAt != nil)
    #expect(backup.resultStatHash == after.statHash)
    let backupURL = try fixture.trashURL(relative: #require(backup.toRelativePath))
    #expect(try Data(contentsOf: backupURL) == originalBytes, "the backup is the file as it was")

    // A backup is not a deletion: the trash-facing queries must not see it.
    #expect(try await fixture.catalog.trashEntry(for: fixture.item.id) == nil)
    #expect(try await fixture.catalog.purgeOlderThan(Date()).isEmpty)
    #expect(try await fixture.catalog.pendingBackups().isEmpty)

    // Retention removes the file and retires the row without touching the live photo.
    let purged = await fixture.editor.purgeExpiredBackups(olderThan: Date().addingTimeInterval(60))
    #expect(purged.count == 1)
    #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    let stillLive = try #require(await fixture.reader.item(id: fixture.item.id))
    #expect(stillLive.trash == .live)
}

@Test func revertRestoresTheBytesAndCanBeRedone() async throws {
    let fixture = try await ReplaceFixture()
    defer { fixture.tearDown() }
    let originalBytes = try Data(contentsOf: fixture.url)

    var recipe = EditRecipe(crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
    recipe.format = OutputFormat(kind: .jpeg)
    #expect(await fixture.editor.replaceOriginal(fixture.item, recipe: recipe).replaced)
    let editedBytes = try Data(contentsOf: fixture.url)
    #expect(editedBytes != originalBytes)

    let item = try #require(await fixture.reader.item(id: fixture.item.id))
    let reverted = await fixture.editor.revertToPreviousVersion(item)
    #expect(reverted.replaced, "\(reverted.message ?? "")")
    #expect(try Data(contentsOf: fixture.url) == originalBytes)

    // The pre-revert bytes are now the newest backup, so a revert can be reverted.
    let itemAgain = try #require(await fixture.reader.item(id: fixture.item.id))
    let redo = await fixture.editor.revertToPreviousVersion(itemAgain)
    #expect(redo.replaced)
    #expect(try Data(contentsOf: fixture.url) == editedBytes)
}

@Test func revertIsRefusedWhenTheFileChangedSinceTheEdit() async throws {
    let fixture = try await ReplaceFixture()
    defer { fixture.tearDown() }

    var recipe = EditRecipe(crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
    recipe.format = OutputFormat(kind: .jpeg)
    #expect(await fixture.editor.replaceOriginal(fixture.item, recipe: recipe).replaced)

    // Someone else saves over the file after the edit.
    try (Data(contentsOf: fixture.url) + Data([0x00, 0x01, 0x02])).write(to: fixture.url)
    let item = try #require(await fixture.reader.item(id: fixture.item.id))
    let outcome = await fixture.editor.revertToPreviousVersion(item)
    #expect(!outcome.replaced)
    #expect(outcome.message?.contains("changed") == true)
}

// MARK: - Fixture

private struct ReplaceFixture {
    let root: URL
    let trash: URL
    let catalog: Catalog
    let reader: CatalogReader
    let editor: EditService
    let item: MediaItem
    let url: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("replace-\(UUID().uuidString)", isDirectory: true)
        trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("catalog.db")
        catalog = try Catalog.open(at: database)
        reader = try CatalogReader.open(at: database)
        let source = try await catalog.addSource(
            displayName: "Library", rootPath: root.path, volumeID: "vol-replace"
        )
        url = root.appendingPathComponent("photo.jpg")
        try Self.writeJPEG(to: url, width: 400, height: 300)
        let stat = try FileStat.read(url)
        let candidate = MediaItem(
            id: MediaID(rawValue: 0),
            identity: FileIdentity(
                volumeID: "vol-replace", documentID: 1, resourceID: nil, statHash: stat.statHash
            ),
            sourceID: source.id,
            relativePath: "photo.jpg",
            parentDirectory: "",
            name: "photo.jpg",
            fileExtension: "jpg",
            kind: .image,
            uniformTypeIdentifier: "public.jpeg",
            byteSize: stat.size,
            stage: .thumbnailed,
            pixelSize: PixelSize(width: 400, height: 300),
            modificationDate: stat.modificationDate,
            creationDate: stat.creationDate
        )
        let ids = try await catalog.recordEnumeration([candidate])
        item = try #require(await reader.item(id: ids[0]))
        let resolver = CatalogMediaResolver(reader: reader, bookmarks: BookmarkStore())
        editor = EditService(resolver: resolver, catalog: catalog, trashRoot: trash)
    }

    func trashURL(relative: String) throws -> URL {
        trash.appendingPathComponent(relative)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeJPEG(to url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}
