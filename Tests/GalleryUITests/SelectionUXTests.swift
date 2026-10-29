import CoreGraphics
import Foundation
import Testing
@testable import GalleryUI
import GalleryDomain

@Suite("Selection UX")
@MainActor struct SelectionUXTests {
    @Test("The marquee picks the cells it intersects, not the ones beside it")
    func marqueeGeometry() {
        let frames: [MediaID: CGRect] = [
            MediaID(rawValue: 1): CGRect(x: 0, y: 0, width: 100, height: 100),
            MediaID(rawValue: 2): CGRect(x: 110, y: 0, width: 100, height: 100),
            MediaID(rawValue: 3): CGRect(x: 0, y: 110, width: 100, height: 100),
        ]
        let picked = Set(Marquee.ids(
            intersecting: CGRect(x: 50, y: 50, width: 70, height: 70), frames: frames
        ))
        #expect(picked == [MediaID(rawValue: 1), MediaID(rawValue: 2), MediaID(rawValue: 3)])

        let none = Marquee.ids(intersecting: .zero, frames: frames)
        #expect(none.isEmpty, "a click with no drag is not a marquee")
    }

    @Test("Trash waits for confirmation and the frozen count is what it says")
    func destructiveConfirmation() async throws {
        let fixture = try await Fixture(files: 10)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        fixture.model.selectAll()
        #expect(fixture.model.selectedCount == 10)

        fixture.model.requestTrash()
        try await fixture.waitUntil { fixture.model.pendingDestructive != nil }
        let pending = try #require(fixture.model.pendingDestructive)
        #expect(pending.count == 10)
        #expect(fixture.model.rowCount == 10, "nothing moves before the dialog is answered")

        fixture.model.cancelDestructive()
        #expect(fixture.model.pendingDestructive == nil)
        #expect(fixture.model.rowCount == 10)

        fixture.model.requestTrash()
        try await fixture.waitUntil { fixture.model.pendingDestructive != nil }
        fixture.model.confirmDestructive()
        try await fixture.waitUntil { fixture.model.rowCount == 0 }
        #expect(fixture.model.selectedCount == 0)
    }

    @Test("A failed item is reported without stopping the rest of the batch")
    func perItemFailures() async throws {
        let fixture = try await Fixture(files: 4)
        defer { await fixture.tearDown() }
        await fixture.model.add([fixture.media])
        try await fixture.settle()
        let nested = fixture.media.appendingPathComponent("IMG", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.media.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: nested.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: fixture.media.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nested.path)
        }

        fixture.model.selectAll()
        await fixture.model.trashSelection()

        #expect(fixture.model.rowCount == 4, "a read-only folder means nothing moved")
        #expect(fixture.model.lastBatchFailures.count == 4)
        #expect(fixture.model.notices.contains { $0.commands.contains(.showBatchFailures) })
    }
}
