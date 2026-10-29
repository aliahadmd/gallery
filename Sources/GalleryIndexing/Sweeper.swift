import Foundation
import GalleryDomain
import GalleryCatalog

/// Which rows the filesystem no longer supports.
///
/// The rule is "a fully-listed directory that does not contain the file", never "absent from this scan":
/// the first is evidence, the second is what a permissions error, a disconnected submount, or a
/// half-finished walk looks like from here — and acting on the second deletes the user's library.
public struct Sweeper: Sendable {
    public init() {}

    /// - Parameters:
    ///   - rows: every row for one source, path columns only.
    ///   - seen: root-relative paths the walk found.
    ///   - trustedDirectories: directories listed completely (`isTrustedListing`).
    ///   - refusedDirectories: directories the walk tried and could not read.
    /// - Returns: ids to retire, in the order the rows came back.
    public func vanishedRows(
        _ rows: [CatalogPathRow],
        seen: Set<String>,
        trustedDirectories: Set<String>,
        refusedDirectories: Set<String> = []
    ) -> [MediaID] {
        rows.compactMap { row in
            // A trashed row's file has *moved* — into ~/.Trash or our own ledger directory. It is supposed
            // to be missing from its old path, and deleting the row would destroy the undo record.
            guard row.trash == .live, !seen.contains(row.relativePath) else { return nil }
            return isProvenAbsent(directory: row.parentDirectory, trusted: trustedDirectories,
                                  refused: refusedDirectories) ? row.id : nil
        }
    }

    /// Walk up from the row's directory to the shallowest one the lister actually reached, and believe that
    /// one. Finding a *refused* ancestor first means we never looked; finding a *trusted* one means the
    /// directory beneath it that used to hold this file is gone, along with the file.
    private func isProvenAbsent(directory: String, trusted: Set<String>, refused: Set<String>) -> Bool {
        var current = directory
        while true {
            if refused.contains(current) { return false }
            if trusted.contains(current) { return true }
            guard let lastSlash = current.lastIndex(of: "/") else { break }
            current = String(current[..<lastSlash])
        }
        // A bare name's parent is the picked folder itself, which the walk reports as `""` rather than as a
        // component — so the climb out of the tree ends here, and a deleted first-level folder is proven by
        // a complete listing of the root.
        return trusted.contains("") && !refused.contains("")
    }
}
