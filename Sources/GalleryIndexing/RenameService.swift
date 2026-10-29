import Foundation
import GalleryCatalog
import GalleryDomain
import GallerySupport

/// Applies a `RenamePlan` to the filesystem and then to the catalog.
///
/// Filesystem first: a crash between the two leaves the bytes where the user asked for them, and the next
/// walk reconciles the row by inode. The only moves that cannot go straight from A to B — swaps, chains and
/// case-only renames — are staged through a dot-name recorded in `rename_journal`, which is deleted on
/// success and replayed at launch.
public actor RenameService {
    public struct Outcome: Sendable {
        public var moved: [MediaID] = []
        public var failed: [MediaID: String] = [:]
        public var cancelled = false
        /// The in-memory undo for the completed prefix. Never persisted; nil when nothing moved.
        public var undo: Undo?
    }

    public struct Undo: Sendable {
        public var moves: [RenameMove]
        public var createdAt: Date

        public init(moves: [RenameMove], createdAt: Date = Date()) {
            self.moves = moves
            self.createdAt = createdAt
        }
    }

    private let catalog: Catalog
    private let reader: CatalogReader
    private let resolver: any MediaResolving
    private let selfWrites: SelfWriteGuard?

    public init(
        catalog: Catalog, reader: CatalogReader, resolver: any MediaResolving,
        selfWrites: SelfWriteGuard? = nil
    ) {
        self.catalog = catalog
        self.reader = reader
        self.resolver = resolver
        self.selfWrites = selfWrites
    }

    public func execute(
        _ plan: RenamePlan, progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> Outcome {
        await run(plan.moves, progress: progress)
    }

    public func undo(
        _ undo: Undo, progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> Outcome {
        let reversed = undo.moves.map { move in
            RenameMove(
                mediaID: move.mediaID, sourceID: move.sourceID,
                fromRelativePath: move.toRelativePath, toRelativePath: move.fromRelativePath,
                fromName: move.toName, toName: move.fromName,
                fromParent: move.toParent, toParent: move.fromParent
            )
        }
        return await run(reversed, progress: progress)
    }

    /// Replays the journal at launch: a staged file goes back to its original name, and a journal row with
    /// nowhere to go is retired.
    @discardableResult
    public func recoverStagedMoves() async -> Int {
        guard let pending = try? await catalog.pendingStagedMoves(), !pending.isEmpty else { return 0 }
        var recovered = 0
        for row in pending {
            guard let mediaID = row.mediaID,
                  let target = await resolver.targets(for: [mediaID])[mediaID] else {
                try? await catalog.finishStagedMoves(ids: [row.id])
                continue
            }
            let parent = target.url.deletingLastPathComponent()
            let to = parent.appendingPathComponent(row.toName)
            let temp = parent.appendingPathComponent(row.tempName)
            let from = parent.appendingPathComponent(row.fromName)
            let scope = target.scopedRoot ?? parent
            if FileManager.default.fileExists(atPath: to.path) {
                try? await catalog.finishStagedMoves(ids: [row.id])
            } else if FileManager.default.fileExists(atPath: temp.path) {
                SecurityScope.begin(scope)
                selfWrites?.note()
                let restored = (try? FileManager.default.moveItem(at: temp, to: from)) != nil
                SecurityScope.end(scope)
                if restored {
                    recovered += 1
                    try? await catalog.finishStagedMoves(ids: [row.id])
                }
            } else {
                try? await catalog.finishStagedMoves(ids: [row.id])
            }
        }
        return recovered
    }

    // MARK: - Execution

    private struct Operation {
        var move: RenameMove
        var item: MediaItem
        var fromURL: URL
        var toURL: URL
        var root: URL
        var staged = false
        var tempURL: URL?
        var journalID: Int64?
        var skip = false
    }

    private func run(
        _ moves: [RenameMove], progress: @Sendable (Int, Int) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        guard !moves.isEmpty else { return outcome }

        let rows = await rows(for: moves.map(\.mediaID))
        let targets = await targets(for: moves.map(\.mediaID))
        var operations: [Operation] = []
        for move in moves {
            guard let item = rows[move.mediaID], let target = targets[move.mediaID] else {
                outcome.failed[move.mediaID] = "The file is no longer in the library."
                continue
            }
            let root = target.scopedRoot ?? Self.root(for: target.url, relativePath: move.fromRelativePath)
            let toURL = root.appendingPathComponent(move.toRelativePath)
            var operation = Operation(
                move: move, item: item, fromURL: target.url, toURL: toURL, root: root
            )
            if !FileManager.default.fileExists(atPath: target.url.path) {
                outcome.failed[move.mediaID] = "The file could not be found."
                operation.skip = true
            }
            operations.append(operation)
        }

        // Staging: a destination that is another move's source (cycle/chain), a case-only rename, or a
        // destination that is the same file under another spelling.
        let fromKeys = Set(operations.map { Self.fold($0.move.fromRelativePath) })
        let toKeys = Set(operations.map { Self.fold($0.move.toRelativePath) })
        for index in operations.indices where !operations[index].skip {
            let fromKey = Self.fold(operations[index].move.fromRelativePath)
            let toKey = Self.fold(operations[index].move.toRelativePath)
            let caseOnly = fromKey == toKey && operations[index].move.fromName != operations[index].move.toName
            // A move participates in a chain when its target is another move's source, or its source is
            // another move's target. Every participant is staged, which vacates all the names the chain
            // needs before any final move runs.
            let chain = (fromKeys.contains(toKey) && toKey != fromKey) || toKeys.contains(fromKey)
            if caseOnly || chain {
                operations[index].staged = true
            } else if FileManager.default.fileExists(atPath: operations[index].toURL.path) {
                let fromStat = try? FileStat.read(operations[index].fromURL)
                let toStat = try? FileStat.read(operations[index].toURL)
                if let fromStat, let toStat, fromStat.inode == toStat.inode {
                    operations[index].staged = true
                } else {
                    outcome.failed[operations[index].move.mediaID] =
                        "“\(operations[index].move.toName)” is already in that folder."
                    operations[index].skip = true
                }
            }
        }

        let roots = Set(operations.filter { !$0.skip }.map(\.root))
        for root in roots { SecurityScope.begin(root) }
        defer { for root in roots { SecurityScope.end(root) } }

        var completed = 0
        let total = operations.filter { !$0.skip }.count

        // Phase 1 — stage.
        for index in operations.indices where operations[index].staged && !operations[index].skip {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            let tempName = Self.temporaryName(for: operations[index].move.fromName)
            let tempURL = operations[index].fromURL.deletingLastPathComponent()
                .appendingPathComponent(tempName)
            do {
                let journalID = try await catalog.beginStagedMove(StagedMove(
                    mediaID: operations[index].item.id,
                    sourceID: operations[index].item.sourceID,
                    parentRelativePath: operations[index].move.fromParent,
                    fromName: operations[index].move.fromName,
                    tempName: tempName,
                    toName: operations[index].move.toName
                ))
                selfWrites?.note()
                try FileManager.default.moveItem(at: operations[index].fromURL, to: tempURL)
                operations[index].tempURL = tempURL
                operations[index].journalID = journalID
            } catch {
                outcome.failed[operations[index].move.mediaID] =
                    "Could not stage the rename: \(error.localizedDescription)"
                operations[index].skip = true
            }
        }

        // Phase 2 — final moves. Direct moves first: their targets are not another move's source, so they
        // are safe; staged moves then land in names already vacated by phase 1.
        let ordered = operations.indices.filter { !operations[$0].skip && !operations[$0].staged }
            + operations.indices.filter { !operations[$0].skip && operations[$0].staged }
        var written: [(Operation, FileStat)] = []
        var journalDone: [Int64] = []
        for index in ordered {
            if outcome.cancelled || Task.isCancelled {
                outcome.cancelled = true
                break
            }
            let source = operations[index].tempURL ?? operations[index].fromURL
            do {
                selfWrites?.note()
                try FileManager.default.moveItem(at: source, to: operations[index].toURL)
                let stat = try FileStat.read(operations[index].toURL)
                written.append((operations[index], stat))
                if let id = operations[index].journalID { journalDone.append(id) }
                completed += 1
                progress(completed, total)
            } catch {
                if let temp = operations[index].tempURL {
                    selfWrites?.note()
                    if (try? FileManager.default.moveItem(at: temp, to: operations[index].fromURL)) != nil,
                       let id = operations[index].journalID {
                        journalDone.append(id)
                    }
                }
                outcome.failed[operations[index].move.mediaID] =
                    "Could not move the file: \(error.localizedDescription)"
            }
        }

        // Phase 3 — catalog, one row at a time, so one contested path cannot roll back the rest. A chain
        // must be written dependents-first (3→4 before 2→3) or the unique path index refuses the middle.
        let orderedWrites = Self.catalogOrder(written)
        let records = orderedWrites.map { operation, stat in
            Self.renameRecord(for: operation, stat: stat)
        }
        if !records.isEmpty {
            if let write = try? await catalog.applyRenames(records) {
                outcome.moved = write.applied
                outcome.failed.merge(write.refused) { first, _ in first }
            } else {
                for record in records {
                    outcome.failed[record.mediaID] =
                        "The file was renamed, but the catalog could not follow; rescan the folder."
                }
            }
        }
        try? await catalog.finishStagedMoves(ids: journalDone)

        let movedSet = Set(outcome.moved)
        let executed = written.map(\.0.move).filter { movedSet.contains($0.mediaID) }
        if !executed.isEmpty {
            outcome.undo = Undo(moves: executed)
        }
        return outcome
    }

    private func rows(for ids: [MediaID]) async -> [MediaID: MediaItem] {
        var result: [MediaID: MediaItem] = [:]
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 500, ids.count)])
            for item in ((try? await reader.items(ids: chunk)) ?? []) { result[item.id] = item }
            index += chunk.count
        }
        return result
    }

    private func targets(for ids: [MediaID]) async -> [MediaID: MediaTarget] {
        var result: [MediaID: MediaTarget] = [:]
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 500, ids.count)])
            result.merge(await resolver.targets(for: chunk)) { first, _ in first }
            index += chunk.count
        }
        return result
    }

    private static func renameRecord(for operation: Operation, stat: FileStat) -> MediaRename {
        var subtype = operation.item.subtype
        let isScreenshot = MediaTypeRules.isScreenshot(
            name: operation.move.toName,
            extension: (operation.move.toName as NSString).pathExtension,
            identifier: operation.item.uniformTypeIdentifier
        )
        if isScreenshot { subtype.insert(.screenshot) } else { subtype.remove(.screenshot) }
        let search = MetadataRules.searchText(
            kind: operation.item.kind, subtype: subtype, codec: operation.item.codec,
            colorSpace: operation.item.colorSpace
        )
        return MediaRename(
            mediaID: operation.item.id,
            expectedStatHash: operation.item.identity.statHash,
            fromRelativePath: operation.item.relativePath,
            toRelativePath: operation.move.toRelativePath,
            parentRelativePath: operation.move.toParent,
            name: operation.move.toName,
            fileExtension: (operation.move.toName as NSString).pathExtension,
            subtype: subtype,
            searchText: search,
            stat: stat
        )
    }

    /// Dependents first: a row whose destination is another pending row's source is written after it.
    private static func catalogOrder(
        _ entries: [(Operation, FileStat)]
    ) -> [(Operation, FileStat)] {
        var remaining = entries
        var result: [(Operation, FileStat)] = []
        while !remaining.isEmpty {
            let index = remaining.firstIndex { candidate in
                !remaining.contains { other in
                    other.0.move.mediaID != candidate.0.move.mediaID
                        && fold(other.0.move.fromRelativePath) == fold(candidate.0.move.toRelativePath)
                }
            }
            guard let index else { break }
            result.append(remaining.remove(at: index))
        }
        result += remaining
        return result
    }

    private static func root(for url: URL, relativePath: String) -> URL {
        var result = url
        for _ in relativePath.split(separator: "/") { result.deleteLastPathComponent() }
        return result
    }

    private static func temporaryName(for name: String) -> String {
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        let base = ".gr-\(token)-"
        let limit = 240 - base.utf8.count - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        if stem.utf8.count > limit { stem = String(stem.prefix(max(1, limit))) }
        return ext.isEmpty ? base + stem : base + stem + "." + ext
    }

    private static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
