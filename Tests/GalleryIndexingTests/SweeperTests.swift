import Testing
import Foundation
import GalleryDomain
import GalleryCatalog
@testable import GalleryIndexing

/// The rule that decides whether a missing file is a deletion or a gap in what we were allowed to see.
/// Everything here is a pure function over path rows and directory sets, so the dangerous cases — a locked
/// folder, a half-finished walk, a trashed photo — are testable without a filesystem.
@Suite("What the sweep is allowed to retire")
struct SweeperTests {
    private let sweeper = Sweeper()

    private func row(_ id: Int64, _ path: String, trash: TrashState = .live) -> CatalogPathRow {
        let parent = (path as NSString).deletingLastPathComponent
        return CatalogPathRow(id: MediaID(rawValue: id), relativePath: path,
                              parentDirectory: parent == "." ? "" : parent, trash: trash)
    }

    @Test("A file missing from a directory that listed everything is gone")
    func provenAbsent() {
        let gone = sweeper.vanishedRows(
            [row(1, "IMG_1.jpg"), row(2, "sub/IMG_2.jpg")],
            seen: [],
            trustedDirectories: ["", "sub"]
        )
        #expect(gone.map(\.rawValue) == [1, 2])
    }

    @Test("A file the walk saw stays")
    func stillPresent() {
        let gone = sweeper.vanishedRows(
            [row(1, "IMG_1.jpg"), row(2, "IMG_2.jpg")],
            seen: ["IMG_1.jpg"],
            trustedDirectories: [""]
        )
        #expect(gone.map(\.rawValue) == [2])
    }

    @Test("A folder we were not allowed to read proves nothing")
    func refusedDirectory() {
        let gone = sweeper.vanishedRows(
            [row(1, "locked/IMG_1.jpg")],
            seen: [],
            trustedDirectories: ["", "open"],
            refusedDirectories: ["locked"]
        )
        #expect(gone.isEmpty, "an EPERM is not a deletion, and retiring the row would delete the user's photo")
    }

    @Test("A refused ancestor protects a directory the walk never reached")
    func refusedAncestor() {
        let gone = sweeper.vanishedRows(
            [row(1, "locked/deeper/IMG_1.jpg")],
            seen: [],
            trustedDirectories: [""],
            refusedDirectories: ["locked"]
        )
        #expect(gone.isEmpty)
    }

    @Test("A deleted directory retires everything under it")
    func deletedDirectory() {
        // The directory is gone, so the walk could not list it. Its parent listed completely and did not
        // contain it, and that is the evidence — at every depth below it.
        let gone = sweeper.vanishedRows(
            [row(1, "gone/IMG_1.jpg"), row(2, "gone/deeper/IMG_2.jpg")],
            seen: [],
            trustedDirectories: [""]
        )
        #expect(gone.map(\.rawValue) == [1, 2])
    }

    @Test("A directory the walk never reached protects its rows")
    func unlistedDirectory() {
        // The cancelled-scan case: `later` was never listed, so its absence from `seen` means nothing.
        let gone = sweeper.vanishedRows(
            [row(1, "later/IMG_1.jpg")],
            seen: [],
            trustedDirectories: []
        )
        #expect(gone.isEmpty)
    }

    @Test("A trashed row is supposed to be missing from its old path")
    func trashedRowsSurvive() {
        let gone = sweeper.vanishedRows(
            [row(1, "IMG_1.jpg", trash: .trashed), row(2, "IMG_2.jpg", trash: .purged), row(3, "IMG_3.jpg")],
            seen: ["IMG_1.jpg"],
            trustedDirectories: [""]
        )
        #expect(gone.map(\.rawValue) == [3], "emptying Trash is the user's decision, not the sweep's")
    }

    @Test("The nearest verdict on the way up wins")
    func deepestVerdictWins() {
        // `sub` was refused, so its trusted parent does not speak for it; `other` was listed, so it does.
        let gone = sweeper.vanishedRows(
            [row(1, "sub/IMG_1.jpg"), row(2, "other/IMG_2.jpg")],
            seen: [],
            trustedDirectories: ["", "other"],
            refusedDirectories: ["sub"]
        )
        #expect(gone.map(\.rawValue) == [2])
    }

    @Test("Only the ids of the rows that really went missing are returned, in order")
    func preservesOrder() {
        let rows = (1...5).map { row(Int64($0), "IMG_\($0).jpg") }
        let gone = sweeper.vanishedRows(rows, seen: ["IMG_2.jpg", "IMG_4.jpg"], trustedDirectories: [""])
        #expect(gone.map(\.rawValue) == [1, 3, 5])
    }
}
