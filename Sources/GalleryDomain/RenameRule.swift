import Foundation

/// How a batch rename rewrites the file's stem. The extension is never touched: changing it would change
/// what the file *is* to every later scan, which is not what a rename means here.
public struct RenameRule: Sendable, Hashable, Codable {
    public struct Sequence: Sendable, Hashable, Codable {
        public enum Placement: String, Sendable, Hashable, Codable {
            case prefix
            case suffix
            case replace
        }

        public var start: Int
        public var step: Int
        public var padding: Int
        public var placement: Placement
        public var separator: String

        public init(
            start: Int = 1, step: Int = 1, padding: Int = 3,
            placement: Placement = .suffix, separator: String = "-"
        ) {
            self.start = start
            self.step = step
            self.padding = padding
            self.placement = placement
            self.separator = separator
        }

        /// `001`, `002` … zero-padded to `padding` (clamped to something a filename can carry).
        public func number(_ ordinal: Int) -> String {
            let value = start + step * ordinal
            return String(format: "%0\(min(max(padding, 1), 12))d", max(0, value))
        }
    }

    public var find: String
    public var replace: String
    public var caseSensitive: Bool
    public var prefix: String
    public var suffix: String
    /// Prepends the capture date (or the fallback) to the stem.
    public var usesCaptureDate: Bool
    public var datePattern: String
    public var dateFallback: String
    public var sequence: Sequence?
    /// Nil keeps the file in its folder; a relative path moves it there (same source only).
    public var destinationFolder: String?

    public init(
        find: String = "", replace: String = "", caseSensitive: Bool = false,
        prefix: String = "", suffix: String = "",
        usesCaptureDate: Bool = false, datePattern: String = "yyyy-MM-dd", dateFallback: String = "undated",
        sequence: Sequence? = nil, destinationFolder: String? = nil
    ) {
        self.find = find
        self.replace = replace
        self.caseSensitive = caseSensitive
        self.prefix = prefix
        self.suffix = suffix
        self.usesCaptureDate = usesCaptureDate
        self.datePattern = datePattern
        self.dateFallback = dateFallback
        self.sequence = sequence
        self.destinationFolder = destinationFolder
    }

    public var isIdentity: Bool {
        find.isEmpty && prefix.isEmpty && suffix.isEmpty && !usesCaptureDate
            && sequence == nil && destinationFolder == nil
    }

    /// A destination the walker would never descend into is a destination whose files disappear on the next
    /// scan. The panel normally supplies a child of the source, but the rule is also a value that can be
    /// built by tests and by the Shortcuts surface, so it validates itself.
    public enum DestinationProblem: Sendable, Hashable, Error {
        case absolute
        case parentTraversal
        case hiddenComponent(String)
        case reservedComponent(String)
        case illegalComponent(String)

        public var message: String {
            switch self {
            case .absolute: "The destination must be relative to the library folder."
            case .parentTraversal: "The destination cannot climb out of the library folder."
            case .hiddenComponent(let name): "Gallery skips “\(name)”: a folder whose name starts with a dot is hidden."
            case .reservedComponent(let name): "Gallery skips “\(name)”: it is not a photo folder."
            case .illegalComponent(let name): "“\(name)” cannot be a folder name here."
            }
        }
    }

    /// Components the walker excludes even though they are not hidden.
    public static let reservedFolderNames: Set<String> = [
        "node_modules", "__pycache__", "venv", "@eadir", "lost+found", "$recycle.bin",
    ]

    public static func destinationProblem(_ path: String) -> DestinationProblem? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return .absolute }
        for raw in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw)
            if component.isEmpty || component == "." { continue }
            if component == ".." { return .parentTraversal }
            if component.hasPrefix(".") { return .hiddenComponent(component) }
            if component.hasSuffix(" ") || component.hasSuffix(".") || component.contains(":") {
                return .illegalComponent(component)
            }
            if component.utf8.count > Limits.filenameBytes { return .illegalComponent(component) }
            if reservedFolderNames.contains(component.lowercased()) {
                return .reservedComponent(component)
            }
        }
        return nil
    }
}

/// One file the planner is allowed to touch. Everything the rule needs, without the catalog.
public struct RenameSubject: Sendable, Hashable {
    public var mediaID: MediaID
    public var sourceID: SourceID
    public var relativePath: String
    public var parentRelativePath: String
    public var name: String
    public var captureDate: Date?
    public var isLivePhotoStill: Bool
    public var isLivePhotoCompanion: Bool
    /// Subjects sharing a key are one unit: the Live Photo still and its video get the same stem.
    public var groupKey: String?
    public var hasFileIdentity: Bool
    public var isOffline: Bool
    public var inTrash: Bool

    public init(
        mediaID: MediaID, sourceID: SourceID, relativePath: String, parentRelativePath: String,
        name: String, captureDate: Date? = nil,
        isLivePhotoStill: Bool = false, isLivePhotoCompanion: Bool = false,
        groupKey: String? = nil, hasFileIdentity: Bool = true,
        isOffline: Bool = false, inTrash: Bool = false
    ) {
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.relativePath = relativePath
        self.parentRelativePath = parentRelativePath
        self.name = name
        self.captureDate = captureDate
        self.isLivePhotoStill = isLivePhotoStill
        self.isLivePhotoCompanion = isLivePhotoCompanion
        self.groupKey = groupKey
        self.hasFileIdentity = hasFileIdentity
        self.isOffline = isOffline
        self.inTrash = inTrash
    }

    public var fileExtension: String {
        let ext = (name as NSString).pathExtension
        return ext
    }

    public var stem: String {
        (name as NSString).deletingPathExtension
    }
}

public enum RenameIssue: Sendable, Hashable, Error {
    case empty
    case tooLong(bytes: Int)
    case illegalCharacters
    case leadingDot
    case trailingCharacter
    case reservedName
    case unchanged
    case collision(String)
    case trashed
    case offline
    case missing
    case invalidDestination(String)

    public var message: String {
        switch self {
        case .empty: "The new name is empty."
        case .tooLong(let bytes): "The new name is \(bytes) bytes; the limit is \(Limits.filenameBytes)."
        case .illegalCharacters: "The name contains /, : or a control character."
        case .leadingDot: "A name starting with a dot is hidden from the library."
        case .trailingCharacter: "A name cannot end with a space or a dot."
        case .reservedName: "That name is reserved by the app or the system."
        case .unchanged: "The name is already correct."
        case .collision(let name): "“\(name)” is already in that folder."
        case .trashed: "The file is in the Trash."
        case .offline: "The file is not downloaded."
        case .missing: "The file is no longer in the library."
        case .invalidDestination(let reason): reason
        }
    }
}

/// One planned move, in relative-path terms so the executor can apply it to the filesystem and the catalog.
public struct RenameMove: Sendable, Hashable {
    public var mediaID: MediaID
    public var sourceID: SourceID
    public var fromRelativePath: String
    public var toRelativePath: String
    public var fromName: String
    public var toName: String
    public var fromParent: String
    public var toParent: String

    public init(
        mediaID: MediaID, sourceID: SourceID, fromRelativePath: String, toRelativePath: String,
        fromName: String, toName: String, fromParent: String, toParent: String
    ) {
        self.mediaID = mediaID
        self.sourceID = sourceID
        self.fromRelativePath = fromRelativePath
        self.toRelativePath = toRelativePath
        self.fromName = fromName
        self.toName = toName
        self.fromParent = fromParent
        self.toParent = toParent
    }
}
