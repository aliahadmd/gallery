import Foundation
import Testing
@testable import GalleryIndexing
@testable import GalleryCatalog
import GalleryDomain
import GallerySupport

@Test func renameMovesFilesKeepsIdentityAndReindexesSearch() async throws {
    let fixture = try await RenameFixture(names: ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
    defer { fixture.tearDown() }
    let id = try #require(fixture.ids["IMG_1.jpg"])
    try await fixture.catalog.setFavorite(id, true)
    let inode = try FileStat.read(fixture.root.appendingPathComponent("IMG_1.jpg")).inode

    let plan = try await fixture.plan(RenameRule(find: "IMG_", replace: "Kyoto-"))
    #expect(plan.moves.count == 3)
    let outcome = await fixture.service.execute(plan)
    #expect(outcome.moved.count == 3, "\(outcome.failed)")

    for index in 1...3 {
        #expect(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("Kyoto-\(index).jpg").path
        ))
    }
    let row = try #require(await fixture.reader.item(id: id))
    #expect(row.name == "Kyoto-1.jpg")
    #expect(row.relativePath == "Kyoto-1.jpg")
    #expect(row.isFavorite, "a rename keeps the favorite")
    #expect(row.stage == .thumbnailed)
    #expect(try FileStat.read(fixture.root.appendingPathComponent("Kyoto-1.jpg")).inode == inode)
    #expect(try await fixture.reader.search("kyoto").count == 3)
    #expect(try await fixture.reader.search("IMG_1").isEmpty, "the old name is gone from the index")
    #expect(outcome.undo != nil)
}

@Test func aChainOfRenamesIsStagedAndLandsCorrectly() async throws {
    let fixture = try await RenameFixture(names: ["1.jpg", "2.jpg", "3.jpg"], contents: ["one", "two", "three"])
    defer { fixture.tearDown() }
    let plan = try await fixture.plan(
        RenameRule(sequence: .init(start: 2, step: 1, padding: 1, placement: .replace))
    )
    #expect(plan.moves.map(\.toName) == ["2.jpg", "3.jpg", "4.jpg"])
    let outcome = await fixture.service.execute(plan)
    #expect(outcome.moved.count == 3, "\(outcome.failed)")

    #expect(try String(contentsOf: fixture.root.appendingPathComponent("2.jpg"), encoding: .utf8) == "one")
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("3.jpg"), encoding: .utf8) == "two")
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("4.jpg"), encoding: .utf8) == "three")
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("1.jpg").path))
    let pending = try await fixture.catalog.pendingStagedMoves()
    #expect(pending.isEmpty, "a completed chain leaves no journal rows")
}

@Test func aCaseOnlyRenameWorksAndKeepsTheInode() async throws {
    let fixture = try await RenameFixture(names: ["a.jpg"])
    defer { fixture.tearDown() }
    let before = try FileStat.read(fixture.root.appendingPathComponent("a.jpg"))
    let plan = try await fixture.plan(RenameRule(find: "a", replace: "A", caseSensitive: true))
    #expect(plan.moves.first?.toName == "A.jpg")
    let outcome = await fixture.service.execute(plan)
    #expect(outcome.moved.count == 1, "\(outcome.failed)")
    let after = try FileStat.read(fixture.root.appendingPathComponent("A.jpg"))
    #expect(after.inode == before.inode)
    let firstID = try #require(fixture.ids["a.jpg"])
    let row = try #require(await fixture.reader.item(id: firstID))
    #expect(row.name == "A.jpg")
}

@Test func undoRestoresTheNamesAndTheIndex() async throws {
    let fixture = try await RenameFixture(names: ["IMG_1.jpg", "IMG_2.jpg"])
    defer { fixture.tearDown() }
    let plan = try await fixture.plan(RenameRule(find: "IMG_", replace: "Kyoto-"))
    let outcome = await fixture.service.execute(plan)
    let undo = try #require(outcome.undo)
    #expect(try await fixture.reader.search("kyoto").count == 2)

    let undone = await fixture.service.undo(undo)
    #expect(undone.moved.count == 2, "\(undone.failed)")
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("IMG_1.jpg").path))
    #expect(try await fixture.reader.search("IMG_1").count == 1)
    #expect(try await fixture.reader.search("kyoto").isEmpty)
}

@Test func aDestinationThatAppearedAfterPlanningIsRefused() async throws {
    let fixture = try await RenameFixture(names: ["a.jpg"])
    defer { fixture.tearDown() }
    let plan = try await fixture.plan(RenameRule(find: "a", replace: "b"))
    #expect(plan.moves.first?.toName == "b.jpg")
    try Data("occupied".utf8).write(to: fixture.root.appendingPathComponent("b.jpg"))

    let outcome = await fixture.service.execute(plan)
    #expect(outcome.moved.isEmpty)
    #expect(outcome.failed[try #require(fixture.ids["a.jpg"])]?.contains("already") == true)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("a.jpg").path))
}

@Test func movingToASubfolderUpdatesTheRowAndUndoBringsItBack() async throws {
    let fixture = try await RenameFixture(names: ["a.jpg", "b.jpg"], folders: ["Sorted"])
    defer { fixture.tearDown() }
    let plan = try await fixture.plan(RenameRule(destinationFolder: "Sorted"))
    #expect(plan.moves.allSatisfy { $0.toParent == "Sorted" })
    let outcome = await fixture.service.execute(plan)
    #expect(outcome.moved.count == 2, "\(outcome.failed)")
    #expect(FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("Sorted/a.jpg").path
    ))
    let firstID = try #require(fixture.ids["a.jpg"])
    let row = try #require(await fixture.reader.item(id: firstID))
    #expect(row.relativePath == "Sorted/a.jpg")
    #expect(row.parentDirectory == "Sorted")

    let undo = try #require(outcome.undo)
    let undone = await fixture.service.undo(undo)
    #expect(undone.moved.count == 2)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("a.jpg").path))
}

@Test func theJournalRollsBackAStagedMoveFromACrash() async throws {
    let fixture = try await RenameFixture(names: ["a.jpg"])
    defer { fixture.tearDown() }
    let id = try #require(fixture.ids["a.jpg"])
    let tempName = ".gr-deadbeef-a.jpg"
    _ = try await fixture.catalog.beginStagedMove(StagedMove(
        mediaID: id, sourceID: fixture.source.id, parentRelativePath: "",
        fromName: "a.jpg", tempName: tempName, toName: "b.jpg"
    ))
    try FileManager.default.moveItem(
        at: fixture.root.appendingPathComponent("a.jpg"),
        to: fixture.root.appendingPathComponent(tempName)
    )

    let recovered = await fixture.service.recoverStagedMoves()
    #expect(recovered == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("a.jpg").path))
    #expect(try await fixture.catalog.pendingStagedMoves().isEmpty)
}

@Test func renamingAwayFromAScreenshotNameReclassifiesIt() async throws {
    let fixture = try await RenameFixture(names: ["Screenshot 2026-10-29.jpg"])
    defer { fixture.tearDown() }
    let id = try #require(fixture.ids["Screenshot 2026-10-29.jpg"])
    let row = try #require(await fixture.reader.item(id: id))
    #expect(row.subtype.contains(.screenshot))

    let plan = try await fixture.plan(RenameRule(find: "Screenshot 2026-10-29", replace: "Holiday"))
    let outcome = await fixture.service.execute(plan)
    #expect(outcome.moved.count == 1)
    let renamed = try #require(await fixture.reader.item(id: id))
    #expect(renamed.name == "Holiday.jpg")
    #expect(!renamed.subtype.contains(.screenshot), "the name no longer says screenshot")
    #expect(renamed.searchText?.contains("screenshot") != true)
}

// MARK: - Fixture

private struct RenameFixture {
    let root: URL
    let catalog: Catalog
    let reader: CatalogReader
    let service: RenameService
    let source: FolderSource
    let ids: [String: MediaID]

    init(names: [String], contents: [String?]? = nil, folders: [String] = []) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let database = root.appendingPathComponent("catalog.db")
        catalog = try Catalog.open(at: database)
        reader = try CatalogReader.open(at: database)
        source = try await catalog.addSource(
            displayName: "Library", rootPath: root.path, volumeID: "vol-rename"
        )
        service = RenameService(
            catalog: catalog, reader: reader,
            resolver: CatalogMediaResolver(reader: reader, bookmarks: BookmarkStore())
        )

        var recorded: [MediaItem] = []
        var ids: [String: MediaID] = [:]
        for (index, name) in names.enumerated() {
            let url = root.appendingPathComponent(name)
            let data = Data((contents?[index] ?? "bytes-\(index)").utf8)
            try data.write(to: url)
            let stat = try FileStat.read(url)
            recorded.append(MediaItem(
                id: MediaID(rawValue: 0),
                identity: FileIdentity(
                    volumeID: "vol-rename", documentID: nil,
                    resourceID: Int64(stat.inode), statHash: stat.statHash
                ),
                sourceID: source.id,
                relativePath: name,
                parentDirectory: "",
                name: name,
                fileExtension: (name as NSString).pathExtension,
                kind: .image,
                subtype: name.lowercased().hasPrefix("screenshot") ? [.screenshot] : [],
                uniformTypeIdentifier: "public.jpeg",
                byteSize: stat.size,
                stage: .thumbnailed,
                pixelSize: PixelSize(width: 64, height: 48),
                searchText: name.lowercased().hasPrefix("screenshot") ? "photo screenshot" : "photo",
                modificationDate: stat.modificationDate,
                creationDate: stat.creationDate
            ))
        }
        let stored = try await catalog.recordEnumeration(recorded)
        for (index, name) in names.enumerated() { ids[name] = stored[index] }
        self.ids = ids
    }

    func plan(_ rule: RenameRule) async throws -> RenamePlan {
        let rows = try await reader.items(ids: Array(ids.values))
        var names: [String: Set<String>] = [:]
        names[""] = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        if let destination = rule.destinationFolder {
            names[destination] = Set((try? FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(destination).path
            )) ?? [])
        }
        let subjects = rows.map { row in
            RenameSubject(
                mediaID: row.id, sourceID: row.sourceID, relativePath: row.relativePath,
                parentRelativePath: row.parentDirectory, name: row.name,
                hasFileIdentity: row.identity.resourceID != nil
            )
        }
        return RenamePlanBuilder.plan(rule, subjects: subjects, existingNames: names)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
