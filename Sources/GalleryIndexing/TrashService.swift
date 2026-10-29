import Foundation
import GalleryCatalog
import GalleryDomain
import GallerySupport

/// Moving files out of the library and back.
///
/// A sandboxed app cannot read `~/.Trash`, so the system Trash is a one-way door: it can put a file there
/// and it can never get it back. Restore is a promise this app makes in the same breath as delete, so the
/// trash it uses is its own — a directory inside the container, addressed by the ledger, which the same
/// grant that moved the file in can move it out again.
///
/// The ledger row is written *before* the move, so a crash between the two leaves a record of a file that
/// is still where it was (recoverable) rather than a file nobody can find.
public actor TrashService {
    public struct Outcome: Sendable, Hashable {
        public var trashed: [MediaID] = []
        public var restored: [MediaID] = []
        public var purged: [MediaID] = []
        public var failed: [MediaID: String] = [:]
    }

    private let catalog: Catalog
    private let resolver: any MediaResolving
    private let root: URL

    /// `root` is the ledger's own directory (`Application Support/GalleryTrash`), never a user folder: a
    /// dot-folder inside the pictures would show up in the user's own file operations.
    public init(catalog: Catalog, resolver: any MediaResolving, root: URL) {
        self.catalog = catalog
        self.resolver = resolver
        self.root = root
    }

    /// Where a trashed file lives once it is out of the library.
    public func location(for entry: TrashLedgerEntry) -> URL? {
        guard let path = entry.toRelativePath else { return nil }
        return root.appendingPathComponent(path)
    }

    public func trash(_ items: [MediaItem]) async -> Outcome {
        var outcome = Outcome()
        for item in items {
            guard let target = await resolver.targets(for: [item.id])[item.id] else {
                outcome.failed[item.id] = "The catalog cannot find this file."
                continue
            }
            let scope = target.scopedRoot ?? target.url
            let ledgerID: Int64
            do {
                ledgerID = try await catalog.beginTrash(TrashLedgerEntry(
                    mediaID: item.id,
                    sourceID: item.sourceID,
                    fromRelativePath: item.relativePath,
                    fromVolumeID: item.identity.volumeID,
                    toRelativePath: nil,
                    mode: .appTrash,
                    byteSize: item.byteSize
                ))
            } catch {
                outcome.failed[item.id] = "Could not record the delete: \(error)"
                continue
            }

            let destination = freeDestination(for: item)
            SecurityScope.begin(scope)
            defer { SecurityScope.end(scope) }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: target.url, to: destination)
                try? await catalog.recordTrashDestination(
                    ledgerID: ledgerID,
                    path: destination.path.replacingOccurrences(of: root.path + "/", with: "")
                )
                try await catalog.finishTrash(ledgerID: ledgerID, mediaID: item.id, succeeded: true, error: nil)
                outcome.trashed.append(item.id)
            } catch {
                // The row goes back to the albums: a file that never left is not deleted.
                try? await catalog.finishTrash(ledgerID: ledgerID, mediaID: item.id,
                                               succeeded: false, error: "\(error)")
                outcome.failed[item.id] = error.localizedDescription
            }
        }
        return outcome
    }

    public func restore(_ items: [MediaItem]) async -> Outcome {
        var outcome = Outcome()
        for item in items {
            guard let entry = try? await catalog.trashEntry(for: item.id) else {
                outcome.failed[item.id] = "There is no record of this item being deleted."
                continue
            }
            guard entry.mode == .appTrash, let source = location(for: entry) else {
                outcome.failed[item.id] = "This file was moved to the system Trash; put it back from Finder."
                continue
            }
            guard let target = await resolver.targets(for: [item.id])[item.id] else {
                outcome.failed[item.id] = "The catalog cannot find this file's folder."
                continue
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                outcome.failed[item.id] = "The file is no longer in Gallery's trash."
                continue
            }
            guard !FileManager.default.fileExists(atPath: target.url.path) else {
                outcome.failed[item.id] = "Another file now has that name. Rename it first."
                continue
            }

            let scope = target.scopedRoot ?? target.url
            SecurityScope.begin(scope)
            defer { SecurityScope.end(scope) }
            do {
                try FileManager.default.createDirectory(at: target.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: target.url)
                try await catalog.restoreFromLedger(ledgerID: entry.id, mediaID: item.id,
                                                    succeeded: true, error: nil)
                outcome.restored.append(item.id)
            } catch {
                try? await catalog.restoreFromLedger(ledgerID: entry.id, mediaID: item.id,
                                                     succeeded: false, error: "\(error)")
                outcome.failed[item.id] = error.localizedDescription
            }
        }
        return outcome
    }

    /// Empty one item out of the trash for good.
    public func purge(_ items: [MediaItem]) async -> Outcome {
        var outcome = Outcome()
        for item in items {
            guard let entry = try? await catalog.trashEntry(for: item.id) else {
                outcome.failed[item.id] = "There is no record of this item being deleted."
                continue
            }
            if let location = location(for: entry), FileManager.default.fileExists(atPath: location.path) {
                do {
                    try FileManager.default.removeItem(at: location)
                } catch {
                    outcome.failed[item.id] = error.localizedDescription
                    continue
                }
            }
            do {
                try await catalog.recordPurge(ledgerID: entry.id, mediaID: item.id)
                outcome.purged.append(item.id)
            } catch {
                outcome.failed[item.id] = "\(error)"
            }
        }
        return outcome
    }

    /// The monthly sweep: entries the catalog says have been in the trash longer than the cutoff lose their
    /// files. Silent by design — a file the user deleted last month does not need an announcement today.
    public func purgeExpired(olderThan cutoff: Date) async -> Outcome {
        var outcome = Outcome()
        let due = (try? await catalog.purgeOlderThan(cutoff)) ?? []
        for entry in due {
            if let location = location(for: entry), FileManager.default.fileExists(atPath: location.path) {
                try? FileManager.default.removeItem(at: location)
            }
            try? await catalog.recordPurge(ledgerID: entry.id, mediaID: entry.mediaID)
            outcome.purged.append(entry.mediaID)
        }
        return outcome
    }

    /// Trashing twice must not overwrite the first copy: the name is the user's, the suffix is ours.
    private func freeDestination(for item: MediaItem) -> URL {
        let base = root
            .appendingPathComponent(String(item.sourceID.rawValue), isDirectory: true)
            .appendingPathComponent(item.relativePath)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        let ext = base.pathExtension
        let unique = ext.isEmpty ? "\(stem)-\(UUID().uuidString.prefix(6))"
                                 : "\(stem)-\(UUID().uuidString.prefix(6)).\(ext)"
        return base.deletingLastPathComponent().appendingPathComponent(unique)
    }
}
