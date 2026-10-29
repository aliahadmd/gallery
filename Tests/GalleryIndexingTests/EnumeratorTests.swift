import Testing
import Foundation
import GalleryDomain
@testable import GalleryIndexing

/// The walk over a real tree, including the two things the sweep depends on: which directories were
/// listed completely, and which were refused.
@Suite("Walking a folder the user picked")
struct EnumeratorTests {
    private func walk(_ root: URL, rules: SkipRules = .default) async -> [EnumeratedDirectory] {
        var directories: [EnumeratedDirectory] = []
        for await directory in Enumerator(rules: rules, directoryConcurrency: 4).walk(root: root) {
            directories.append(directory)
        }
        return directories
    }

    private func paths(_ directories: [EnumeratedDirectory]) -> Set<String> {
        Set(directories.flatMap(\.entries).map(\.relativePath))
    }

    private func skipCount(_ directories: [EnumeratedDirectory], _ rule: SkipRule) -> Int {
        directories.compactMap { $0.skipCounts[rule] }.reduce(0, +)
    }

    @Test("Shallow files reach the grid before deep ones")
    func breadthFirst() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("a.jpg")
        try fixture.file("sub/b.jpg")
        try fixture.file("sub/deep/c.jpg")

        let directories = await walk(fixture.root)
        let order = directories.map(\.relativePath)
        #expect(order.first == "", "the picked folder itself is listed first")
        let shallow = try #require(order.firstIndex(of: "sub"))
        let deep = try #require(order.firstIndex(of: "sub/deep"))
        #expect(shallow < deep, "a level-order walk paints the first page without waiting for the deepest card")
        #expect(paths(directories) == ["a.jpg", "sub/b.jpg", "sub/deep/c.jpg"])
    }

    @Test("A bundle is not a folder of photos")
    func packages() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("Photos Library.photoslibrary/private/foo.jpeg")
        try fixture.file("IMG_1.jpg")

        let directories = await walk(fixture.root)
        #expect(paths(directories) == ["IMG_1.jpg"])
        #expect(skipCount(directories, .package) == 1)
        // The bundle's own path never appears as a directory: the walk decided before entering.
        #expect(!directories.contains { $0.relativePath.hasPrefix("Photos Library.photoslibrary") })
    }

    @Test("A symlinked folder would be walked twice")
    func symlinkedDirectory() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("real/a.jpg")
        try fixture.symlink("link", to: fixture.url("real"))

        let directories = await walk(fixture.root)
        #expect(paths(directories) == ["real/a.jpg"])
        #expect(skipCount(directories, .symbolicLink) == 1)
    }

    @Test("A file symlink is not a second copy of a picture")
    func symlinkedFile() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("a.jpg")
        try fixture.symlink("b.jpg", to: fixture.url("a.jpg"))

        let directories = await walk(fixture.root)
        #expect(paths(directories) == ["a.jpg"])
        #expect(skipCount(directories, .symbolicLink) == 1)
    }

    @Test("A refused directory reports a failure instead of an empty listing",
          .enabled(if: FixtureTree.canDenyAccess))
    func unreadableDirectory() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("locked/inside.jpg")
        try fixture.file("open/inside.jpg")
        try fixture.makeUnreadable("locked")

        let directories = await walk(fixture.root)
        let locked = try #require(directories.first { $0.relativePath == "locked" })
        #expect(locked.failure != nil, "absence must never be reported the same way an empty folder is")
        #expect(!locked.isTrustedListing)
        let open = try #require(directories.first { $0.relativePath == "open" })
        #expect(open.isTrustedListing)
        // The rest of the tree is still walked; one locked folder does not stop the scan.
        #expect(paths(directories).contains("open/inside.jpg"))
    }

    @Test("Only gallery extensions become entries")
    func nonMediaFiles() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("a.jpg")
        try fixture.file("notes.txt")
        try fixture.file("archive.zip")
        try fixture.file("IMG_1.MOV")

        let directories = await walk(fixture.root)
        #expect(paths(directories) == ["a.jpg", "IMG_1.MOV"])
        #expect(skipCount(directories, .notMedia) >= 2)
    }

    @Test("Dot-files are skipped until asked for, and a directory listing still sees them")
    func hiddenFiles() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file(".secret.jpg")
        try fixture.file("a.jpg")

        let skipped = await walk(fixture.root)
        #expect(paths(skipped) == ["a.jpg"])
        #expect(skipCount(skipped, .hiddenFile) == 1)

        let shown = await walk(fixture.root, rules: SkipRules(includesHiddenFiles: true))
        #expect(paths(shown).contains(".secret.jpg"))
    }

    @Test("A file too big to decode keeps its row and says why")
    func tooLarge() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("huge.jpg", bytes: 4096)
        try fixture.file("fine.jpg", bytes: 64)

        let directories = await walk(fixture.root, rules: SkipRules(maximumFileBytes: 1000))
        let entries = directories.flatMap(\.entries)
        #expect(entries.count == 2, "the oversized file is a Problems row, not a missing file")
        let huge = try #require(entries.first { $0.name == "huge.jpg" })
        #expect(huge.error == .tooLarge)
        #expect(entries.first { $0.name == "fine.jpg" }?.error == IndexError.none)
    }

    @Test("A directory with too many files is reported as unfinished")
    func fanOut() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        for index in 0..<6 { try fixture.file("p\(index).jpg") }

        let directories = await walk(fixture.root, rules: SkipRules(maximumFilesPerDirectory: 3))
        let root = try #require(directories.first { $0.relativePath == "" })
        #expect(root.entries.count == 3)
        #expect(root.truncatedFileCount == 3)
        #expect(!root.isTrustedListing, "a partial listing proves nothing about the files it left out")
    }

    @Test("Depth is capped, and the cap stops the descent rather than the scan")
    func depth() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("one/two.jpg")
        try fixture.file("one/deeper/three.jpg")
        try fixture.file("top.jpg")

        let directories = await walk(fixture.root, rules: SkipRules(maximumDepth: 1))
        // `one` is depth 1 and is listed; `one/deeper` is depth 2 and is cut, so the file inside it is
        // never seen — and the listing of `one` stays trusted because it was complete.
        #expect(paths(directories) == ["top.jpg", "one/two.jpg"])
        #expect(skipCount(directories, .depthLimit) == 1)
    }

    @Test("A rename keeps the file's identity, which is what favorites ride on")
    func identitySurvivesRename() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        let original = try fixture.file("IMG_1.jpg")

        let before = await walk(fixture.root)
        let first = try #require(before.flatMap(\.entries).first)
        // On this system `documentIdentifierKey` answers nil for ordinary APFS files, so the inode is the
        // identity that has to work — it is the fallback the catalog keys on.
        let identifier = try #require(first.resourceID)

        let renamed = fixture.url("IMG_1-renamed.jpg")
        try FileManager.default.moveItem(at: original, to: renamed)

        let after = await walk(fixture.root)
        let second = try #require(after.flatMap(\.entries).first)
        #expect(second.relativePath == "IMG_1-renamed.jpg")
        #expect(second.resourceID == identifier, "the same file must land on the same row, not a new one")
    }

    @Test("The live-photo halves are marked while both are still in one directory")
    func livePhotoPairInsideATree() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.file("IMG_7.HEIC", modified: moment)
        try fixture.file("IMG_7.MOV", modified: moment)

        let entries = (await walk(fixture.root)).flatMap(\.entries)
        let still = try #require(entries.first { $0.name == "IMG_7.HEIC" })
        let clip = try #require(entries.first { $0.name == "IMG_7.MOV" })
        #expect(still.kind == .image && clip.kind == .video)
        #expect(still.subtype.contains(.livePhoto))
        #expect(clip.subtype.contains(.livePhotoCompanion))
    }

    @Test("Every entry arrives with the columns pass A can fill and pass B cannot")
    func stubRowsAreReady() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        try fixture.file("sub/IMG_1.jpg", bytes: 2048)

        let entry = try #require((await walk(fixture.root)).flatMap(\.entries).first)
        #expect(entry.relativePath == "sub/IMG_1.jpg")
        #expect(entry.parentDirectory == "sub")
        #expect(entry.stage == .classified)
        #expect(entry.byteSize == 2048)
        #expect(entry.modificationDate != nil)
        #expect(entry.statHash != 0)

        let item = entry.mediaItem(sourceID: SourceID(rawValue: 7), volumeID: "vol-1")
        #expect(item.id.rawValue == 0, "the catalog's upsert owns the row id")
        #expect(item.relativePath == "sub/IMG_1.jpg")
        #expect(item.identity.volumeID == "vol-1")
        #expect(item.searchText == nil, "pass A has no decoded text to offer")
    }

    @Test("A consumer that stops reading ends the walk")
    func cancellation() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        for index in 0..<40 { try fixture.file("d\(index)/p\(index).jpg") }

        let stream = Enumerator(rules: .default, directoryConcurrency: 2).walk(root: fixture.root)
        let seen = await Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count == 3 { break }
            }
            return count
        }.value
        #expect(seen == 3, "`break` must finish the stream instead of leaving the walker enumerating")
    }

    @Test("A slow consumer never loses a directory")
    func backpressureKeepsEveryDirectory() async throws {
        let fixture = try FixtureTree()
        defer { fixture.cleanup() }
        for index in 0..<300 {
            try fixture.file("roll-\(index)/IMG_\(index).jpg")
        }

        var listed: Set<String> = []
        for await directory in Enumerator().walk(root: fixture.root) {
            listed.insert(directory.relativePath)
            // The app's consumer writes a batch per directory; this stands in for that work so the walk is
            // provably faster than its reader — the case a bounded buffer used to answer by dropping folders.
            try await Task.sleep(for: .milliseconds(2))
        }

        #expect(listed.count == 301, "the root and all 300 folders")
    }
}
