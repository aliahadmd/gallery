import CoreGraphics
import Foundation
import GalleryCatalog
import GalleryDomain
import GalleryEditing
import GallerySupport

/// The catalog-facing half of editing: it turns a row into a file the editor can work on, and owns the
/// exporter and previewer the UI talks to.
///
/// It stays an actor so a preview render, an export and (from the next milestones) an in-place metadata
/// write cannot interleave on the same file.
public actor EditService {
    private let resolver: any MediaResolving
    private let catalog: Catalog
    private let trashRoot: URL
    private let selfWrites: SelfWriteGuard?
    private let previewer: EditPreviewer
    private let exporter: Exporter
    private let composer: CollageComposer
    /// ImageIO's metadata copy is fast, but the re-encode fallback is not; one narrow lane keeps both off
    /// the cooperative pool and out of each other's way.
    private let metadataLane = BlockingLane(
        label: "app.gallery.metadata", qos: .userInitiated, semaphore: AsyncSemaphore(value: 1)
    )

    public init(
        resolver: any MediaResolving,
        catalog: Catalog,
        trashRoot: URL,
        selfWrites: SelfWriteGuard? = nil,
        previewer: EditPreviewer = EditPreviewer(),
        exporter: Exporter = Exporter(),
        composer: CollageComposer = CollageComposer()
    ) {
        self.resolver = resolver
        self.catalog = catalog
        self.trashRoot = trashRoot
        self.selfWrites = selfWrites
        self.previewer = previewer
        self.exporter = exporter
        self.composer = composer
    }

    /// What the file carries now, for the metadata form.
    public func metadata(for source: EditSource) async -> ExistingMetadata {
        let scope = source.scopedRoot ?? source.url.deletingLastPathComponent()
        let outcome = await metadataLane.run { () -> ExistingMetadata? in
            SecurityScope.begin(scope)
            defer { SecurityScope.end(scope) }
            return MetadataEditor.readBack(source.url)
        }
        guard case .completed(let metadata) = outcome else { return .none }
        return metadata ?? .none
    }

    public struct MetadataOutcome: Sendable {
        public var written: Bool
        public var message: String?

        public init(written: Bool, message: String? = nil) {
            self.written = written
            self.message = message
        }
    }

    /// Writes the fields into the file, in place, then commits the projection to the catalog. The file's
    /// mtime is restored because the pixels did not change: the poster and the analysis stay valid.
    ///
    /// The write truncates and rewrites in place, which is the only way to keep the inode (and with it the
    /// favorites, Finder tags and capture date). That leaves a crash window; a copy in the backup ledger
    /// before the first byte is written is what makes it recoverable, and it also gives metadata edits the
    /// same Revert affordance Replace Original has.
    public func applyMetadata(_ overrides: MetadataOverrides, to item: MediaItem) async -> MetadataOutcome {
        guard !overrides.isEmpty else { return MetadataOutcome(written: true) }
        guard let target = await resolver.targets(for: [item.id])[item.id] else {
            return MetadataOutcome(written: false, message: "The file could not be found.")
        }
        let scope = target.scopedRoot ?? target.url.deletingLastPathComponent()
        guard let original = try? FileStat.read(target.url) else {
            return MetadataOutcome(written: false, message: "The file could not be read.")
        }

        let relative = backupPath(for: item)
        let backupURL = trashRoot.appendingPathComponent(relative)
        let ledgerID: Int64
        do {
            try FileManager.default.createDirectory(
                at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            ledgerID = try await catalog.beginBackup(TrashLedgerEntry(
                mediaID: item.id, sourceID: item.sourceID, fromRelativePath: item.relativePath,
                fromVolumeID: item.identity.volumeID, mode: .editBackup, byteSize: original.size
            ))
            let copied = await metadataLane.run { () -> Bool in
                SecurityScope.begin(scope)
                defer { SecurityScope.end(scope) }
                do {
                    try FileManager.default.copyItem(at: target.url, to: backupURL)
                    return true
                } catch {
                    return false
                }
            }
            guard case .completed(true) = copied,
                  let backup = try? FileStat.read(backupURL), backup.size == original.size else {
                try? FileManager.default.removeItem(at: backupURL)
                try? await catalog.failBackup(ledgerID: ledgerID, error: "the backup was incomplete")
                return MetadataOutcome(
                    written: false,
                    message: "The backup could not be written; the original was not changed."
                )
            }
            try await catalog.recordBackupDestination(ledgerID: ledgerID, path: relative)
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            return MetadataOutcome(written: false, message: "The backup could not be written: \(error)")
        }

        let prepared = await metadataLane.run { () -> MetadataStep in
            SecurityScope.begin(scope)
            defer { SecurityScope.end(scope) }
            return Self.prepare(overrides, url: target.url)
        }
        guard case .completed(let step) = prepared else {
            return MetadataOutcome(written: false, message: "The edit was cancelled.")
        }
        if case .prepared(_, _, true) = step {
            Log.editing.info("metadata: \(item.name, privacy: .public) needed a full re-encode")
        }
        guard case .prepared(let values, let stat, let reencoded) = step else {
            if case .failed(let reason) = step {
                return MetadataOutcome(written: false, message: reason)
            }
            return MetadataOutcome(written: false)
        }

        let capture = values.capture.map { edit -> CaptureMoment in
            let zone = edit.offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) }
            return CaptureMoment(
                instant: edit.instant,
                wallClock: edit.instant,
                timeZone: zone,
                source: zone == nil ? .exifDateTimeOriginal : .exifOffsetTimeOriginal
            )
        }
        let projection = EditProjection(title: values.title, capture: capture, gps: values.gps)
        do {
            // The file is on disk in its new form; the ledger records what a revert would need even if the
            // catalog commit below loses its CAS.
            try await catalog.completeBackup(ledgerID: ledgerID, resultStatHash: stat.statHash)
            let committed = try await catalog.commitEdit(MediaEditCommit(
                mediaID: item.id,
                expectedStatHash: item.identity.statHash,
                stat: stat,
                pixelsChanged: false,
                projection: projection
            ))
            guard committed else {
                return MetadataOutcome(
                    written: false,
                    message: "The file changed while it was being edited. Revert restores the backup."
                )
            }
            return MetadataOutcome(
                written: true,
                message: reencoded ? "This format needed a full re-encode." : nil
            )
        } catch {
            return MetadataOutcome(written: false, message: "\(error)")
        }
    }

    // MARK: - Replace, revert and recovery

    public struct ReplaceOutcome: Sendable {
        public var replaced: Bool
        public var message: String?
        public var backupDate: Date?
        public var reverted = false

        public init(replaced: Bool, message: String? = nil, backupDate: Date? = nil, reverted: Bool = false) {
            self.replaced = replaced
            self.message = message
            self.backupDate = backupDate
            self.reverted = reverted
        }
    }

    /// Replaces the file at its own path, keeping a previous version first.
    ///
    /// Same container only: a format change moves the path and churns `rel_path`, the extension and the
    /// search index, which is what Export a Copy is for. The write goes over the descriptor, so the inode,
    /// Finder tags and the creation date survive; the mtime moves so the poster and analysis are redone.
    public func replaceOriginal(_ item: MediaItem, recipe: EditRecipe) async -> ReplaceOutcome {
        guard item.kind == .image else {
            return ReplaceOutcome(replaced: false, message: "Only photos can be replaced.")
        }
        guard let target = await resolver.targets(for: [item.id])[item.id] else {
            return ReplaceOutcome(replaced: false, message: "The file could not be found.")
        }
        guard let sourceKind = OutputFormats.kind(for: target.url), sourceKind == recipe.format.kind else {
            return ReplaceOutcome(
                replaced: false,
                message: "Replace Original keeps the file's type. Use Export a Copy to convert."
            )
        }
        let scope = target.scopedRoot ?? target.url.deletingLastPathComponent()
        SecurityScope.begin(scope)
        defer { SecurityScope.end(scope) }
        guard let original = try? FileStat.read(target.url) else {
            return ReplaceOutcome(replaced: false, message: "The file could not be read.")
        }

        let staging = target.url.deletingLastPathComponent()
            .appendingPathComponent(".gallery-replace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        Self.sweepStaleTemps(in: target.url.deletingLastPathComponent())
        let source = EditSource(
            mediaID: item.id, url: target.url, scopedRoot: target.scopedRoot, kind: item.kind,
            name: item.name, modificationDate: item.modificationDate, captureDate: item.capture?.instant
        )
        switch await exporter.export(ExportRequest(source: source, recipe: recipe), to: staging) {
        case .failure(let error):
            return ReplaceOutcome(replaced: false, message: error.userMessage)
        case .success:
            break
        }

        let ledgerID: Int64
        let relative = backupPath(for: item)
        let backupURL = trashRoot.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(
                at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            ledgerID = try await catalog.beginBackup(TrashLedgerEntry(
                mediaID: item.id, sourceID: item.sourceID, fromRelativePath: item.relativePath,
                fromVolumeID: item.identity.volumeID, mode: .editBackup, byteSize: original.size
            ))
            try FileManager.default.copyItem(at: target.url, to: backupURL)
            try await catalog.recordBackupDestination(ledgerID: ledgerID, path: relative)
            guard let backup = try? FileStat.read(backupURL), backup.size == original.size else {
                try? await catalog.failBackup(ledgerID: ledgerID, error: "the backup was incomplete")
                try? FileManager.default.removeItem(at: backupURL)
                return ReplaceOutcome(
                    replaced: false, message: "The backup could not be verified; the original was not changed."
                )
            }
        } catch {
            return ReplaceOutcome(replaced: false, message: "The backup could not be written: \(error)")
        }

        do {
            selfWrites?.note()
            let stamp = max(Date(), original.modificationDate.addingTimeInterval(0.001))
            try InPlaceWriter.overwrite(target.url, with: staging, modificationDate: stamp)
            let stat = try FileStat.read(target.url)
            try await catalog.completeBackup(ledgerID: ledgerID, resultStatHash: stat.statHash)
            let committed = try await catalog.commitEdit(MediaEditCommit(
                mediaID: item.id, expectedStatHash: item.identity.statHash, stat: stat,
                pixelsChanged: true
            ))
            guard committed else {
                return ReplaceOutcome(
                    replaced: false,
                    message: "The library changed while the file was replaced. Revert to restore the backup."
                )
            }
            Log.editing.info("replace: \(item.name, privacy: .public) rewritten in place, backup kept")
            return ReplaceOutcome(replaced: true, backupDate: Date())
        } catch {
            try? await catalog.failBackup(ledgerID: ledgerID, error: "\(error)")
            return ReplaceOutcome(replaced: false, message: "\(error)")
        }
    }

    /// Puts the newest backup back, after keeping the current bytes as the next backup — so a revert can be
    /// reverted. Refused when the file has changed since the edit, because that would undo newer work.
    public func revertToPreviousVersion(_ item: MediaItem) async -> ReplaceOutcome {
        guard let target = await resolver.targets(for: [item.id])[item.id] else {
            return ReplaceOutcome(replaced: false, message: "The file could not be found.")
        }
        guard let backup = try? await catalog.latestBackup(mediaID: item.id),
              let relative = backup.toRelativePath else {
            return ReplaceOutcome(replaced: false, message: "There is no previous version to restore.")
        }
        let backupURL = trashRoot.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            return ReplaceOutcome(replaced: false, message: "The backup file is missing.")
        }
        let scope = target.scopedRoot ?? target.url.deletingLastPathComponent()
        SecurityScope.begin(scope)
        defer { SecurityScope.end(scope) }
        guard let current = try? FileStat.read(target.url) else {
            return ReplaceOutcome(replaced: false, message: "The file could not be read.")
        }
        if let expected = backup.resultStatHash, expected != current.statHash {
            return ReplaceOutcome(
                replaced: false,
                message: "The photo has changed since the edit, so reverting would undo newer work."
            )
        }

        let redoRelative = backupPath(for: item)
        let redoURL = trashRoot.appendingPathComponent(redoRelative)
        do {
            try FileManager.default.createDirectory(
                at: redoURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let ledgerID = try await catalog.beginBackup(TrashLedgerEntry(
                mediaID: item.id, sourceID: item.sourceID, fromRelativePath: item.relativePath,
                fromVolumeID: item.identity.volumeID, mode: .editBackup, byteSize: current.size
            ))
            try FileManager.default.copyItem(at: target.url, to: redoURL)
            try await catalog.recordBackupDestination(ledgerID: ledgerID, path: redoRelative)

            selfWrites?.note()
            let stamp = max(Date(), current.modificationDate.addingTimeInterval(0.001))
            try InPlaceWriter.overwrite(target.url, with: backupURL, modificationDate: stamp)
            let stat = try FileStat.read(target.url)
            let committed = try await catalog.commitEdit(MediaEditCommit(
                mediaID: item.id, expectedStatHash: item.identity.statHash, stat: stat,
                pixelsChanged: true
            ))
            guard committed else {
                return ReplaceOutcome(replaced: false, message: "The library changed; try again.")
            }
            // The redo backup's "result" is the bytes this revert just produced, so a second revert is
            // allowed and a later external edit is still refused.
            try await catalog.completeBackup(ledgerID: ledgerID, resultStatHash: stat.statHash)
            try await catalog.recordBackupRestored(ledgerID: backup.id)
            Log.editing.info("revert: \(item.name, privacy: .public) restored from its backup")
            return ReplaceOutcome(replaced: true, reverted: true)
        } catch {
            try? FileManager.default.removeItem(at: redoURL)
            return ReplaceOutcome(replaced: false, message: "\(error)")
        }
    }

    /// The date of the newest restorable backup, for the editor's "Revert" affordance.
    public func backupDate(for mediaID: MediaID) async -> Date? {
        (try? await catalog.latestBackup(mediaID: mediaID))?.trashedAt
    }

    /// Rows whose write never completed. A backup that exists is left in place and offered as a revert; a
    /// ledger row with no destination means the original was never touched, so it is retired.
    @discardableResult
    public func recoverInterruptedEdits() async -> Int {
        guard let pending = try? await catalog.pendingBackups() else { return 0 }
        var restorable = 0
        for row in pending {
            if row.toRelativePath == nil {
                try? await catalog.failBackup(ledgerID: row.id, error: "interrupted before the backup")
            } else {
                restorable += 1
            }
        }
        return restorable
    }

    /// Previous versions older than the cutoff. Their ledger rows are retired here; the files are removed by
    /// the caller, which knows where the trash root is.
    @discardableResult
    public func purgeExpiredBackups(olderThan cutoff: Date) async -> [TrashLedgerEntry] {
        let expired = (try? await catalog.purgeExpiredBackups(olderThan: cutoff)) ?? []
        for row in expired {
            if let relative = row.toRelativePath {
                try? FileManager.default.removeItem(at: trashRoot.appendingPathComponent(relative))
            }
        }
        return expired
    }

    private func backupPath(for item: MediaItem) -> String {
        "versions/\(item.sourceID.rawValue)/\(UUID().uuidString)/\(item.relativePath)"
    }

    /// A crash between truncate and the final chunk leaves a `.gallery-meta-*` temp behind. It names no
    /// original, so it cannot be restored — but the backup ledger covers recovery; this only stops the
    /// debris accumulating in the user's folders. The age floor keeps a write that is still running (another
    /// instance, a slow network volume) out of reach.
    private static func sweepStaleTemps(in directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".gallery-meta-") || name.hasPrefix(".gallery-replace-") else { continue }
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private enum MetadataStep: Sendable {
        case prepared(MetadataValues, FileStat, reencoded: Bool)
        case failed(String)
    }

    private static func prepare(_ overrides: MetadataOverrides, url: URL) -> MetadataStep {
        guard let original = try? FileStat.read(url) else {
            return .failed("The file could not be read.")
        }
        let existing = MetadataEditor.readBack(url) ?? .none
        let values = MetadataValues.resolve(overrides, existing: existing)
        sweepStaleTemps(in: url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".gallery-meta-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }

        switch MetadataEditor.rewrite(url, overrides: overrides, existing: existing, to: temp) {
        case .failed:
            return .failed("The file could not be written.")
        case .dropped(let field):
            return .failed("This file's format cannot store the \(field).")
        case .written(let reencoded):
            do {
                try InPlaceWriter.overwrite(
                    url, with: temp, modificationDate: original.modificationDate
                )
            } catch {
                return .failed("The file could not be written in place.")
            }
            guard let stat = try? FileStat.read(url) else {
                return .failed("The file could not be read back.")
            }
            return .prepared(values, stat, reencoded: reencoded)
        }
    }

    /// The file behind a row, with the grant that covers it. Nil when the source's folder cannot be found —
    /// a bookmark that no longer resolves is a photo the editor must not pretend to open.
    public func source(for item: MediaItem) async -> EditSource? {
        guard let target = await resolver.targets(for: [item.id])[item.id] else { return nil }
        return EditSource(
            mediaID: item.id,
            url: target.url,
            scopedRoot: target.scopedRoot,
            kind: item.kind,
            name: item.name,
            modificationDate: item.modificationDate,
            captureDate: item.capture?.instant
        )
    }

    public func preview(
        for source: EditSource, recipe: EditRecipe, maxLongSide: Int
    ) async -> CGImage? {
        await previewer.preview(for: source, recipe: recipe, maxLongSide: maxLongSide)
    }

    public func exportCopy(_ request: ExportRequest, to destination: URL) async -> Result<URL, ExportError> {
        await exporter.export(request, to: destination)
    }

    public func exportCopies(
        _ requests: [ExportRequest],
        to folder: URL,
        policy: ExportNaming.Policy,
        progress: @escaping @Sendable (Exporter.Progress) -> Void
    ) async -> Exporter.Outcome {
        await exporter.export(requests, to: folder, policy: policy, progress: progress)
    }

    public func cancelExport() async {
        await exporter.cancel()
    }

    public func collagePreview(
        _ document: CollageDocument,
        members: [MediaID: EditSource],
        sourceLongSides: [MediaID: Int],
        previewLongSide: Int?
    ) async -> CGImage? {
        await composer.render(
            document, members: members, sourceLongSides: sourceLongSides,
            previewLongSide: previewLongSide
        )
    }

    public func writeCollage(
        _ document: CollageDocument,
        members: [MediaID: EditSource],
        sourceLongSides: [MediaID: Int],
        to url: URL
    ) async -> Bool {
        await composer.write(document, members: members, sourceLongSides: sourceLongSides, to: url)
    }
}
