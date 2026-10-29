import Foundation
import GalleryDomain
import GallerySupport

/// One directory exactly as the walk saw it — including whether it can be trusted.
///
/// `failure` is the field the sweep depends on: a refused directory proves nothing about the files under
/// it, so treating its absence as deletion would silently retire rows the user still owns.
public struct EnumeratedDirectory: Sendable, Hashable {
    /// Root-relative, `""` for the root itself.
    public var relativePath: String
    public var entries: [ScannedEntry]
    public var subdirectoryCount: Int
    public var skipCounts: [SkipRule: Int]
    /// nil means the listing succeeded.
    public var failure: String?
    /// Files dropped because the directory exceeded the fan-out limit.
    public var truncatedFileCount: Int

    public init(relativePath: String, entries: [ScannedEntry], subdirectoryCount: Int = 0,
                skipCounts: [SkipRule: Int] = [:], failure: String? = nil, truncatedFileCount: Int = 0) {
        self.relativePath = relativePath
        self.entries = entries
        self.subdirectoryCount = subdirectoryCount
        self.skipCounts = skipCounts
        self.failure = failure
        self.truncatedFileCount = truncatedFileCount
    }

    /// Safe to sweep: listed completely, so anything missing here is genuinely missing.
    public var isTrustedListing: Bool { failure == nil && truncatedFileCount == 0 }
}

/// A walk that cannot outrun its consumer.
///
/// `AsyncStream` drops buffered elements when the reader falls behind, and for a directory walk a dropped
/// element is not "a slow scan" — it is files that were never listed, which the sweep then reads as deleted
/// photos. So the walk hands the consumer a bounded number of listings ahead of it and waits for a permit
/// otherwise. The permit comes back when the consumer asks for the next directory, which with `for await`
/// is exactly "I have finished with the last one".
public struct DirectoryWalk: AsyncSequence, Sendable {
    public typealias Element = EnumeratedDirectory

    private let stream: AsyncStream<EnumeratedDirectory>
    private let permits: AsyncSemaphore

    init(stream: AsyncStream<EnumeratedDirectory>, permits: AsyncSemaphore) {
        self.stream = stream
        self.permits = permits
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncStream<EnumeratedDirectory>.Iterator
        private let permits: AsyncSemaphore

        init(base: AsyncStream<EnumeratedDirectory>.Iterator, permits: AsyncSemaphore) {
            self.base = base
            self.permits = permits
        }

        public mutating func next() async -> EnumeratedDirectory? {
            let directory = await base.next()
            if directory != nil { permits.release() }
            return directory
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator(), permits: permits)
    }
}


/// fast on a tree with a thousand subfolders.
///
/// Manual BFS rather than `FileManager.enumerator(at:)`, because that enumerator cannot be cancelled,
/// reports no per-directory failures, and blocks one cooperative-pool thread for the entire walk of a
/// 100k-file tree. Here each listing runs `@concurrent` — a blocking `contentsOfDirectory` on the
/// cooperative pool is how a scan makes the UI stutter — and an `AsyncSemaphore` caps how many run at
/// once, because more parallelism at a spinning platter or an SMB share makes enumeration slower.
public struct Enumerator: Sendable {
    public var rules: SkipRules
    public var directoryConcurrency: Int

    public init(rules: SkipRules = .default, directoryConcurrency: Int = Enumerator.recommendedDirectoryConcurrency) {
        self.rules = rules
        self.directoryConcurrency = max(1, directoryConcurrency)
    }

    /// Half the cores, clamped to 2…8. Disk-latency bound work does not scale with core count.
    public static var recommendedDirectoryConcurrency: Int {
        min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    struct Node: Sendable {
        var url: URL
        var relativePath: String
        var depth: Int

        func childPath(_ name: String) -> String {
            relativePath.isEmpty ? name : "\(relativePath)/\(name)"
        }
    }

    private struct Listing: Sendable {
        var directory: EnumeratedDirectory
        var children: [Node]
    }

    /// The keys pass A needs. Requested up front so `contentsOfDirectory(includingPropertiesForKeys:)`
    /// prefills them and the per-file `resourceValues` reads below are cache hits, not syscalls.
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
        .isHiddenKey, .contentTypeKey, .documentIdentifierKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
    ]

    /// Directories and their files, as they are listed. Cancelling the consuming task stops the walk;
    /// cancelling the returned stream's consumer is the only handle the caller needs.
    public func walk(root: URL) -> DirectoryWalk {
        let rules = rules
        let gate = AsyncSemaphore(value: directoryConcurrency)
        // How far the walk may run ahead of its consumer. Deep enough that a burst of fast listings is not
        // throttled, shallow enough that a deep tree is never held in memory.
        let permits = AsyncSemaphore(value: max(16, directoryConcurrency * 8))

        let stream = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let walker = Task(priority: .utility) {
                var frontier = [Node(url: root, relativePath: "", depth: 0)]
                while !frontier.isEmpty {
                    if Task.isCancelled { break }
                    let wave = frontier
                    let next = await withTaskGroup(of: Listing.self, returning: [Node].self) { group in
                        for node in wave {
                            group.addTask(priority: .utility) {
                                // The permit is taken before the listing starts, not before the yield: the
                                // bound has to cover a wave of sibling directories too, or a tree a thousand
                                // folders wide fills memory faster than the consumer can drain it.
                                do {
                                    try await permits.acquire()
                                } catch {
                                    return Listing(
                                        directory: EnumeratedDirectory(relativePath: node.relativePath,
                                                                       entries: [], failure: "not listed"),
                                        children: []
                                    )
                                }
                                do {
                                    return try await gate.withPermit { await Self.list(node: node, rules: rules) }
                                } catch {
                                    // Only `gate` throws, and only when this task is already being cancelled —
                                    // so the walk ends after this wave. Reporting the directory as unlisted is
                                    // the honest answer, and it keeps the sweep from reading a gap as a deletion.
                                    return Listing(
                                        directory: EnumeratedDirectory(relativePath: node.relativePath,
                                                                       entries: [], failure: "not listed"),
                                        children: []
                                    )
                                }
                            }
                        }
                        var additions: [Node] = []
                        for await listing in group {
                            additions.append(contentsOf: listing.children)
                            continuation.yield(listing.directory)
                        }
                        return additions
                    }
                    frontier = next
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in walker.cancel() }
        }
        return DirectoryWalk(stream: stream, permits: permits)
    }

    /// Lists one directory. Never throws: a refusal is data, and the caller has to be able to tell
    /// "nothing here" apart from "could not look".
    @concurrent
    private static func list(node: Node, rules: SkipRules) async -> Listing {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: node.url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            let failure = Self.describe(error)
            return Listing(directory: EnumeratedDirectory(relativePath: node.relativePath, entries: [],
                                                          failure: failure), children: [])
        }

        var entries: [ScannedEntry] = []
        var children: [Node] = []
        var skips: [SkipRule: Int] = [:]
        var truncated = 0

        for url in urls {
            let name = url.lastPathComponent
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Self.resourceKeys)
            } catch {
                skips[.unreadable, default: 0] += 1
                continue
            }

            if values.isDirectory == true {
                if let rule = rules.reasonToSkipDirectory(
                    name: name,
                    pathExtension: url.pathExtension,
                    isPackage: values.isPackage == true,
                    isSymbolicLink: values.isSymbolicLink == true,
                    isAlias: values.isAliasFile == true,
                    depth: node.depth + 1
                ) {
                    skips[rule, default: 0] += 1
                } else {
                    children.append(Node(url: url, relativePath: node.childPath(name), depth: node.depth + 1))
                }
                continue
            }

            // Measured, not assumed: a link reports `isSymbolicLink` *and* `isAliasFile`, and neither
            // `isDirectory` nor `isRegularFile` — the filesystem does not resolve it here. So this test has
            // to come before the regular-file one, or every link is filed under "not a photo" and the
            // Problems count says the wrong reason. A link to a folder also cannot be descended, because it
            // never becomes a child node in the first place.
            if values.isSymbolicLink == true { skips[.symbolicLink, default: 0] += 1; continue }
            if values.isAliasFile == true { skips[.aliasFile, default: 0] += 1; continue }

            // Sockets, fifos and device nodes are not files a gallery can show, and reading one blocks.
            guard values.isRegularFile == true else { skips[.notMedia, default: 0] += 1; continue }

            let byteSize = Int64(values.fileSize ?? 0)
            let rule = rules.reasonToSkipFile(name: name, fileExtension: url.pathExtension,
                                              isHidden: values.isHidden == true,
                                              isAlias: values.isAliasFile == true, byteSize: byteSize)
            if let rule, rule != .tooLarge {
                skips[rule, default: 0] += 1
                continue
            }

            let classification = MediaTypeRules.classify(name: name, fileExtension: url.pathExtension,
                                                         contentType: values.contentType)
            guard classification.isGalleryContent else { skips[.notMedia, default: 0] += 1; continue }

            if entries.count >= rules.maximumFilesPerDirectory {
                truncated += 1
                continue
            }

            let isOffline = values.isUbiquitousItem == true
                && values.ubiquitousItemDownloadingStatus != .current
            entries.append(ScannedEntry(
                relativePath: node.childPath(name),
                parentDirectory: node.relativePath,
                name: name,
                fileExtension: url.pathExtension,
                documentID: ScannedEntry.identifier(values.documentIdentifier),
                resourceID: Self.inode(of: url),
                byteSize: byteSize,
                modificationDate: values.contentModificationDate,
                creationDate: values.creationDate,
                kind: classification.kind,
                subtype: classification.subtype,
                uniformTypeIdentifier: classification.uniformTypeIdentifier,
                stage: .classified,
                error: rule == .tooLarge ? .tooLarge : .none,
                isOffline: isOffline
            ))
        }

        MediaTypeRules.markLivePhotoPairs(&entries)
        return Listing(
            directory: EnumeratedDirectory(relativePath: node.relativePath, entries: entries,
                                           subdirectoryCount: children.count, skipCounts: skips,
                                           truncatedFileCount: truncated),
            children: children
        )
    }

    private static func describe(_ error: Error) -> String {
        let bridge = error as NSError
        return "\(bridge.domain) \(bridge.code): \(bridge.localizedDescription)"
    }

    /// The file's inode, which on APFS is its file ID and survives a rename or a same-volume move.
    ///
    /// Measured rather than assumed: on this system `documentIdentifierKey` comes back `nil` for ordinary
    /// files, and `fileResourceIdentifierKey` hands back an opaque `NSObject` whose number cannot be read
    /// out of it. One `stat` per candidate file is the only way to get an identity at all, and it runs on
    /// the `@concurrent` listing thread, off the cooperative pool.
    private static func inode(of url: URL) -> Int64? {
        var buffer = stat()
        guard stat(url.path, &buffer) == 0 else { return nil }
        return Int64(buffer.st_ino)
    }
}
