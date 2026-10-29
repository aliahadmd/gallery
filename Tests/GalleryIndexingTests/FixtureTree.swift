import Foundation
import GalleryIndexing

/// A throwaway folder tree for the walk tests. Real directories and real files, because the rules under
/// test are about what macOS reports for them — `isPackage`, `isSymbolicLink`, `fileSize`, the type a
/// `.jpg` resolves to — not about what we imagine it reports.
final class FixtureTree {
    let root: URL
    private var denied: [String] = []

    init(name: String = #function) throws {
        let sanitized = name.replacingOccurrences(of: "()", with: "").replacingOccurrences(of: "/", with: "-")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-fixtures", isDirectory: true)
            .appendingPathComponent("\(sanitized)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Restores permissions before deleting: a subtree left at mode 000 would make `removeItem` fail and
    /// leak the fixture into the temp directory forever. Tracked rather than walked, because a 000
    /// directory is also a directory `subpathsOfDirectory` cannot descend into.
    func cleanup() {
        for path in denied { chmod(url(path).path, 0o755) }
        chmod(root.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relativePath: String) -> URL {
        relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let destination = url(relativePath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    /// A file of `bytes` zeroed bytes with the given modification time. Contents do not matter to pass A —
    /// it reads `stat`, and the type comes from the extension.
    @discardableResult
    func file(_ relativePath: String, bytes: Int = 512, modified: Date? = nil) throws -> URL {
        let destination = url(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: destination)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
        }
        return destination
    }

    func symlink(_ relativePath: String, to target: URL) throws {
        let destination = url(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
    }

    /// Mode 000 is how a folder the user cannot read arrives, which is the case the sweep must survive.
    func makeUnreadable(_ relativePath: String) throws {
        denied.append(relativePath)
        chmod(url(relativePath).path, 0o000)
    }

    func makeReadable(_ relativePath: String) throws {
        chmod(url(relativePath).path, 0o755)
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url(relativePath))
    }

    /// Whether this process can be denied access at all; root is not stopped by a mode.
    static let canDenyAccess = geteuid() != 0
}

extension FixtureTree {
    /// The paths a walk reported, sorted, so a test says what the tree contained rather than what order
    /// `readdir` happened to return.
    static func sortedPaths(_ directories: [EnumeratedDirectory]) -> [String] {
        directories.flatMap(\.entries).map(\.relativePath).sorted()
    }
}
