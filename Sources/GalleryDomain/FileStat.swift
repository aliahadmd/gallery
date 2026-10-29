import Foundation

/// What a catalog row remembers about the file, plus the inode that proves an in-place write kept identity.
public struct FileStat: Sendable, Hashable {
    public var size: Int64
    public var modificationDate: Date
    public var creationDate: Date?
    public var inode: UInt64
    public var statHash: UInt64

    public init(
        size: Int64, modificationDate: Date, creationDate: Date?, inode: UInt64, statHash: UInt64
    ) {
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.inode = inode
        self.statHash = statHash
    }

    /// The same hash pass A computes, so a committed edit and the next walk agree about the file.
    public static func read(_ url: URL) throws -> FileStat {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let created = attributes[.creationDate] as? Date
        var info = stat()
        let inode = stat(url.path, &info) == 0 ? UInt64(info.st_ino) : 0
        return FileStat(
            size: size,
            modificationDate: modified,
            creationDate: created,
            inode: inode,
            statHash: GalleryDomain.statHash(size: size, modificationDate: modified,
                                              creationDate: created)
        )
    }
}
