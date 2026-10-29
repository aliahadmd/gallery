import Foundation
import ImageIO
import Testing
@testable import GalleryUI
import GalleryDomain
import GalleryEditing
import GalleryIndexing

@Suite("Editor")
@MainActor struct EditorModelTests {
    @Test("Opening a photo builds a session with a preview and its native size")
    func openBuildsSession() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "edit.jpg", width: 640, height: 480)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.items.first?.pixelSize != nil }

        let item = try #require(fixture.model.items.first)
        #expect(fixture.model.canEdit(item))
        await fixture.model.openEditor(item.id)
        let session = try #require(fixture.model.editingSession)
        #expect(fixture.model.editorID == item.id)
        #expect(session.outputSize == PixelSize(width: 640, height: 480))
        #expect(session.preview != nil)
        #expect(session.isIdentity, "nothing has been changed yet, so an export would be a byte copy")

        fixture.model.closeEditor()
        #expect(fixture.model.editingSession == nil)
    }

    @Test("Crop, rotation and undo move the planned output size")
    func geometryFollowsTheRecipe() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "geometry.jpg", width: 640, height: 480)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.items.first?.pixelSize != nil }

        let item = try #require(fixture.model.items.first)
        await fixture.model.openEditor(item.id)
        let session = try #require(fixture.model.editingSession)
        #expect(session.isIdentity)

        session.setCrop(CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(session.outputSize == PixelSize(width: 320, height: 240))
        #expect(!session.isIdentity)
        #expect(session.canUndo)

        session.rotate(clockwise: true)
        #expect(session.outputSize == PixelSize(width: 240, height: 320))
        session.undo()
        #expect(session.outputSize == PixelSize(width: 320, height: 240))

        session.setResize(.longSide(120))
        #expect(session.outputSize == PixelSize(width: 120, height: 90))
        #expect(!session.wasClamped)
        session.setResize(.longSide(4000))
        #expect(session.outputSize == PixelSize(width: 320, height: 240),
                "a long side larger than the crop must not enlarge it")
        #expect(session.wasClamped)
    }

    @Test("Export writes the edited copy and leaves the original untouched")
    func exportWritesACopy() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "export.jpg", width: 640, height: 480)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.items.first?.pixelSize != nil }

        let item = try #require(fixture.model.items.first)
        await fixture.model.openEditor(item.id)
        let session = try #require(fixture.model.editingSession)
        session.setCrop(CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        session.setFormat(.png)

        let sourceData = try Data(contentsOf: session.source.url)
        let destination = fixture.directory.appendingPathComponent("exported.png")
        await fixture.model.exportEditorCopy(to: destination)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let header = try #require(EditRenderer.readHeader(destination))
        #expect(header.size == PixelSize(width: 320, height: 240))
        #expect(try Data(contentsOf: session.source.url) == sourceData,
                "the original must be byte-identical after an export")
        #expect(fixture.model.notices.contains { $0.text.contains("Exported") })
    }

    @Test("Typing a caption updates the recipe and clears cleanly")
    func markOverlayEditsTheRecipe() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "mark.jpg", width: 640, height: 480)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.items.first?.pixelSize != nil }

        let item = try #require(fixture.model.items.first)
        await fixture.model.openEditor(item.id)
        let session = try #require(fixture.model.editingSession)
        session.beginInteraction()
        session.setOverlayText("HELLO")
        session.endInteraction()
        #expect(session.overlay?.text == "HELLO")
        #expect(session.recipe.overlays.count == 1)
        #expect(session.canUndo)

        session.setOverlayPlacement(
            .tiled(angleDegrees: -30, columnSpacingFraction: 0.3, rowSpacingFraction: 0.3),
            kind: .watermark
        )
        #expect(session.overlay?.kind == .watermark)
        #expect(session.overlay?.placement != nil)

        session.undo()
        #expect(session.overlay?.text == "HELLO")
        session.clearOverlay()
        #expect(session.recipe.overlays.isEmpty)
    }

    @Test("Export a Copy on a selection writes one file per photo")
    func batchExportWritesEveryCopy() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "one.jpg", width: 320, height: 240)
        try fixture.writeJPEG(named: "two.jpg", width: 320, height: 240)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.items.count == 2 }

        let out = fixture.directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let ids = fixture.model.items.filter { $0.kind == .image }.map(\.id)
        await fixture.model.exportCopies(ids, to: out, policy: .init())

        let names = Set((try FileManager.default.contentsOfDirectory(atPath: out.path)))
        #expect(names == ["one.jpg", "two.jpg"])
        #expect(fixture.model.exportProgress == nil)
        #expect(fixture.model.notices.contains { $0.text.contains("2 copies") })
    }

    @Test("A collage composes two photos and exports the canvas")
    func collageBuildsAndExports() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "left.jpg", width: 320, height: 240)
        try fixture.writeJPEG(named: "right.jpg", width: 320, height: 240)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil {
            fixture.model.items.count == 2 && fixture.model.items.allSatisfy { $0.pixelSize != nil }
        }

        let ids = fixture.model.items.map(\.id)
        await fixture.model.createCollage(ids)
        let session = try #require(fixture.model.collageSession)
        #expect(fixture.model.isCollageOpen)
        #expect(session.memberCount == 2)
        #expect(session.preview != nil)
        #expect(session.layout.slots.count == 2)
        #expect(session.upscaleFactor > 1, "two 320 px photos in a 3000 px canvas must report enlargement")

        let destination = fixture.directory.appendingPathComponent("collage.jpg")
        await fixture.model.exportCollage(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let header = try #require(EditRenderer.readHeader(destination))
        #expect(header.size == session.layout.canvas)

        fixture.model.closeCollage()
        #expect(!fixture.model.isCollageOpen)
    }

    @Test("Metadata is written into the file and the row follows without a rescan")
    func metadataWritesIntoTheFile() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "meta.jpg", width: 320, height: 240)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil { fixture.model.items.first?.pixelSize != nil }

        let item = try #require(fixture.model.items.first)
        await fixture.model.openEditor(item.id)
        let source = try #require(await fixture.editor.source(for: item))
        let originalMTime = item.modificationDate

        let written = await fixture.model.applyMetadata(
            MetadataOverrides(title: .set("Kyoto at dusk")), to: [item.id]
        )
        #expect(written)
        #expect(MetadataEditor.readBack(source.url)?.title == "Kyoto at dusk")

        let updated = try #require(await fixture.reader.item(id: item.id))
        #expect(updated.title == "Kyoto at dusk")
        #expect(updated.stage == .thumbnailed)
        if let originalMTime, let newMTime = updated.modificationDate {
            #expect(abs(newMTime.timeIntervalSince(originalMTime)) < 1,
                    "a metadata edit restores the mtime so the poster stays valid")
        }
        #expect(try await fixture.reader.search("kyoto").first?.item.id == item.id)
    }

    @Test("Batch metadata writes a title into every selected file and can be undone")
    func batchMetadataWritesAndUndoes() async throws {
        let fixture = try await Fixture(files: 0)
        defer { await fixture.tearDown() }
        try fixture.writeJPEG(named: "one.jpg", width: 320, height: 240)
        try fixture.writeJPEG(named: "two.jpg", width: 320, height: 240)
        await fixture.model.start()
        await fixture.model.add([fixture.media])
        try await fixture.waitUntilIdle(fixture.coordinator)
        try await fixture.waitUntil {
            fixture.model.items.count == 2 && fixture.model.items.allSatisfy { $0.pixelSize != nil }
        }

        fixture.model.selectAll()
        await fixture.model.beginBatchMetadata()
        let session = try #require(fixture.model.batchMetadataSession)
        session.applyTitle = true
        session.title = "Kyoto"
        await fixture.model.applyBatchMetadata()

        for item in fixture.model.items {
            let row = try #require(await fixture.reader.item(id: item.id))
            #expect(row.title == "Kyoto")
            let source = try #require(await fixture.editor.source(for: row))
            #expect(MetadataEditor.readBack(source.url)?.title == "Kyoto")
        }
        #expect(fixture.model.notices.contains { $0.commands.contains(.undoMetadata) })

        await fixture.model.undoLastMetadataChange()
        for item in fixture.model.items {
            let row = try #require(await fixture.reader.item(id: item.id))
            #expect(row.title == nil)
            let source = try #require(await fixture.editor.source(for: row))
            #expect(MetadataEditor.readBack(source.url)?.title == nil)
        }
    }

    @Test("A clip cannot be opened in the editor")
    func clipsAreRefused() async throws {
        let fixture = try await Fixture(files: 5)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()

        let clip = try #require(fixture.model.items.first { $0.kind == .video })
        #expect(!fixture.model.canEdit(clip))
        await fixture.model.openEditor(clip.id)
        #expect(fixture.model.editingSession == nil)
        #expect(fixture.model.notices.contains { $0.text.contains("Only photos") })
    }
}
