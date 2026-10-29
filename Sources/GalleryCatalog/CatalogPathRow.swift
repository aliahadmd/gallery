import Foundation
import GalleryDomain

/// A media row seen only through its path. The sweep compares paths; giving it full `MediaItem`s would
/// decode a hundred thousand rows to read three columns.
public struct CatalogPathRow: Sendable, Hashable {
    public var id: MediaID
    public var relativePath: String
    public var parentDirectory: String
    public var trash: TrashState

    public init(id: MediaID, relativePath: String, parentDirectory: String, trash: TrashState) {
        self.id = id
        self.relativePath = relativePath
        self.parentDirectory = parentDirectory
        self.trash = trash
    }
}
