import Foundation
import GalleryDomain

/// What the editing pipeline needs to know about a file, without the catalog. This is the seam that keeps
/// `GalleryEditing` independent of `GalleryIndexing`: the indexer builds it from a `MediaItem`, the editor
/// from whatever the model resolved.
public struct EditSource: Sendable, Hashable {
    public var mediaID: MediaID
    public var url: URL
    /// The granted folder the file lives in; writes inside it need no further permission.
    public var scopedRoot: URL?
    public var kind: MediaKind
    public var name: String
    public var modificationDate: Date?
    public var captureDate: Date?

    public init(
        mediaID: MediaID,
        url: URL,
        scopedRoot: URL? = nil,
        kind: MediaKind = .image,
        name: String,
        modificationDate: Date? = nil,
        captureDate: Date? = nil
    ) {
        self.mediaID = mediaID
        self.url = url
        self.scopedRoot = scopedRoot
        self.kind = kind
        self.name = name
        self.modificationDate = modificationDate
        self.captureDate = captureDate
    }

    public var fileExtension: String { url.pathExtension.lowercased() }
}

/// The naming policy for "Export a Copy…", kept pure against an injected `taken` so a batch can reserve
/// every name before it touches the disk.
public enum ExportNaming {
    public struct Policy: Sendable, Hashable, Codable {
        public enum Stem: String, Sendable, Hashable, Codable {
            case same
            case editedSuffix
            case captureDate
        }

        public enum Collision: String, Sendable, Hashable, Codable {
            case number
            case overwrite
            case skip
        }

        public var stem: Stem
        public var customPrefix: String
        public var collision: Collision

        public init(stem: Stem = .same, customPrefix: String = "", collision: Collision = .number) {
            self.stem = stem
            self.customPrefix = customPrefix
            self.collision = collision
        }
    }

    public static func stem(for source: EditSource, policy: Policy) -> String {
        let base = (source.name as NSString).deletingPathExtension
        let prefix = sanitized(policy.customPrefix)
        switch policy.stem {
        case .same:
            return prefix + base
        case .editedSuffix:
            return prefix + base + "-edited"
        case .captureDate:
            let date = source.captureDate ?? source.modificationDate
            let stamp = date.map(dayString) ?? "undated"
            return prefix + stamp + " " + base
        }
    }

    /// Nil means "do not write this file" (a `.skip` collision), not an error.
    public static func fileName(
        for source: EditSource,
        format: OutputFormat,
        policy: Policy,
        taken: (String) -> Bool
    ) -> String? {
        let stem = stem(for: source, policy: policy)
        let ext = format.fileExtension
        let first = "\(stem).\(ext)"
        guard taken(first) else { return first }

        switch policy.collision {
        case .skip:
            return nil
        case .overwrite:
            return first
        case .number:
            for index in 2...9_999 {
                let candidate = "\(stem)-\(index).\(ext)"
                if !taken(candidate) { return candidate }
            }
            return nil
        }
    }

    private static func sanitized(_ prefix: String) -> String {
        prefix
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
