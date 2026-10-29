import Foundation

/// Why the walk stopped looking at something. The distinction matters for more than logging: a directory
/// that was *refused* is not evidence that its files are gone, and the sweep must not treat it as such.
public enum SkipRule: String, Sendable, Hashable, CaseIterable {
    /// A folder the filesystem presents as one file — `Photos Library.photoslibrary`, iMovie tickets,
    /// Keynote documents. Its insides are somebody else's database.
    case package
    /// A dot-folder or a system/vcs directory that never contains user photos.
    case excludedName
    case symbolicLink
    case aliasFile
    case hiddenFile
    /// Extension is not a photo or video format at all, so the file is not gallery content.
    case notMedia
    /// Kept as a row with an error instead of dropped: the user owns the file and "it is missing and
    /// nobody will say why" is the worst possible outcome.
    case tooLarge
    case depthLimit
    /// The filesystem refused to describe the file at all — a mid-flight deletion, or a share that hung.
    /// Not evidence about the file's type, so it becomes no row, but it is counted: a directory that
    /// silently yields nothing looks identical to a directory that is empty.
    case unreadable
}

/// The hard rules of the walk. Every one of them exists because of something a real `~/Pictures` contains.
public struct SkipRules: Sendable, Hashable {
    /// How far the walk descends before it assumes the user did not mean a gallery. 24 is generous for
    /// `DCIM/102APPLE`-style nesting and shallow enough that a mistake at `/` cannot run for an hour.
    public var maximumDepth: Int
    /// Files one directory may contribute. A stray `node_modules` of thumbnails or a mounted Time Machine
    /// snapshot would otherwise dominate a scan.
    public var maximumFilesPerDirectory: Int
    /// Above this, decoding is a project, not a thumbnail. iPhone cinematic footage and 8K ProRes live
    /// under it; disk images and VM bundles do not reach the classifier anyway.
    public var maximumFileBytes: Int64
    /// Dot-files are almost never photos a user wants to browse, but a hidden `.jpg` is still a file the
    /// user could un-hide and expect to see, so the rule is opt-in rather than baked in.
    public var includesHiddenFiles: Bool

    public init(
        maximumDepth: Int = 24,
        maximumFilesPerDirectory: Int = 50_000,
        maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024,
        includesHiddenFiles: Bool = false
    ) {
        self.maximumDepth = maximumDepth
        self.maximumFilesPerDirectory = maximumFilesPerDirectory
        self.maximumFileBytes = maximumFileBytes
        self.includesHiddenFiles = includesHiddenFiles
    }

    public static let `default` = SkipRules()

    /// Names that are never a photo album, whatever their contents. Compared case-insensitively because
    /// exFAT and SMB shares arrive with `$Recycle.bin` next to `$RECYCLE.BIN`.
    public static let excludedDirectoryNames: Set<String> = [
        ".trash", ".trash-1000", "#recycle", "$recycle.bin", ".documentrevisions-v100",
        ".spotlight-v100", ".fseventsd", ".vol", ".temporaryitems", ".temporaryonedriveitems",
        ".onecache", ".appleinternal", ".apdisk", ".metadata", ".thumbnails", ".cphd",
        "node_modules", ".git", ".hg", ".svn", ".cache", ".venv", "venv", "__pycache__",
        "@eadir", ".synologytransactionlogs", ".sync", ".ds_store", ".localized",
    ]

    /// Extensions that mean "this might be a photo or video". Deliberately a closed set rather than
    /// `UTType.conforms(to: .image)`: a file whose extension is unknown to ImageIO still belongs in
    /// Problems, and only an extension the gallery claims is worth a row.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "hif", "gif", "tif", "tiff",
        "bmp", "webp", "avif", "jxl", "raw", "cr2", "cr3", "nef", "nrw", "dng", "orf", "ori",
        "rw2", "raf", "sr2", "srf", "srw", "arw", "sff", "pef", "ptx", "rwl", "3fr", "fff",
        "iiq", "eip", "mef", "mos", "x3f", "rwl", "rdc", "dcr", "drd", "erv", "kdc", "wdp",
        "hdp", "jxr", "jp2", "ico", "cur", "psd", "qoi",
    ]

    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "qt", "avi", "mkv", "webm", "mpg", "mpeg", "mpe", "mts", "m2ts",
        "mod", "tod", "3gp", "3g2", "mj2", "wmv", "flv", "f4v", "vob", "svi", "gxf", "mxf",
        "cr2", "cr3", "mxv", "r3d", "braw", "rmov", "ogv", "dv", "hdv", "insv", "amp4",
    ]

    public static func isMediaExtension(_ fileExtension: String) -> Bool {
        imageExtensions.contains(fileExtension) || videoExtensions.contains(fileExtension)
    }

    /// Directory suffixes that are bundles belonging to another app. Checked by name as well as by
    /// `isPackage`, because LaunchServices only reports a directory as a package once it has looked inside
    /// — and the one thing we must not do on the first touch of `~/Pictures` is descend into
    /// `Photos Library.photoslibrary` and treat its thumbnails as the user's library.
    public static let packageExtensions: Set<String> = [
        "photoslibrary", "imoveticket", "app", "framework", "bundle", "kext", "plugin", "xpc",
        "key", "keynote", "pages", "numbers", "craft", "sketch",
    ]

    /// Should the walk descend into this child directory?
    public func reasonToSkipDirectory(
        name: String,
        pathExtension: String,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isAlias: Bool,
        depth: Int
    ) -> SkipRule? {
        // A symlinked folder is the classic loop: `~/Pictures/Archive -> ~/Pictures`. Following it walks
        // the same tree twice and invents duplicate rows for files that exist once.
        if isSymbolicLink || isAlias { return .symbolicLink }
        if isPackage || Self.packageExtensions.contains(pathExtension.lowercased()) { return .package }
        if Self.excludedDirectoryNames.contains(name.lowercased()) { return .excludedName }
        // Dot-folders that are not packages are still not albums, unless the name is on the list above.
        if name.hasPrefix(".") { return .excludedName }
        if depth > maximumDepth { return .depthLimit }
        return nil
    }

    /// Should this file become a row? `nil` means index it; `.notMedia` means it is not the gallery's
    /// business at all, `.tooLarge` means keep the row and say why it will never show a picture.
    public func reasonToSkipFile(
        name: String,
        fileExtension: String,
        isHidden: Bool,
        isAlias: Bool,
        byteSize: Int64
    ) -> SkipRule? {
        if isAlias { return .aliasFile }
        if isHidden && !includesHiddenFiles { return .hiddenFile }
        if name == ".DS_Store" { return .excludedName }
        if !Self.isMediaExtension(fileExtension.lowercased()) { return .notMedia }
        if byteSize > maximumFileBytes { return .tooLarge }
        return nil
    }
}
