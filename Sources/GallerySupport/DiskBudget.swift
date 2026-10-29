import Foundation

public struct DiskBudget: Sendable {
    public struct EvictionReport: Sendable, Equatable {
        public let removed: Int
        public let freedBytes: Int64
    }

    private let directory: URL
    private let byteLimit: Int64

    public init(directory: URL, byteLimit: Int64) {
        self.directory = directory.standardizedFileURL
        self.byteLimit = byteLimit
    }

    public func usedBytes() -> Int64 {
        candidates().reduce(0) { $0 + $1.size }
    }

    /// `untilUnderBudget` stops the sweep at the budget line; with `false` the caller wants the tree
    /// emptied regardless (disk-pressure flush). A file the catalog never dated cannot be *proven*
    /// cold, so it sorts last — every dated file is evicted before it.
    public func evict(untilUnderBudget: Bool, lastUsed: @Sendable (URL) -> Date?) -> EvictionReport {
        let ranked = candidates()
            .map { (url: $0.url, size: $0.size, date: lastUsed($0.url) ?? .distantFuture) }
            .sorted { ($0.date, $0.url.path) < ($1.date, $1.url.path) }
        var used = ranked.reduce(Int64(0)) { $0 + $1.size }
        var removed = 0
        var freed: Int64 = 0
        for item in ranked {
            if untilUnderBudget && used <= byteLimit { break }
            do {
                try FileManager.default.removeItem(at: item.url)
            } catch {
                continue
            }
            used -= item.size
            freed += item.size
            removed += 1
        }
        return EvictionReport(removed: removed, freedBytes: freed)
    }

    private struct Candidate: Sendable {
        let url: URL
        let size: Int64
    }

    private func candidates() -> [Candidate] {
        let root = directory
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: []
        ) else { return [] }
        var result: [Candidate] = []
        for case let fileURL as URL in enumerator {
            let url = fileURL.standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values?.isDirectory != true, let fileSize = values?.fileSize else { continue }
            result.append(Candidate(url: url, size: Int64(fileSize)))
        }
        return result
    }
}
