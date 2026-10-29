import Foundation
import UniformTypeIdentifiers
import GalleryDomain

/// What a file is, decided from `stat` and the type the filesystem already knows. This is pass A's whole
/// opinion: no decoding, so it costs microseconds per file and still fills the grid with the right tiles.
public struct Classification: Sendable, Hashable {
    public var kind: MediaKind
    public var subtype: MediaSubtype
    public var uniformTypeIdentifier: String
    /// False when neither the extension nor the declared type is something a gallery should own a row for.
    public var isGalleryContent: Bool

    public init(kind: MediaKind, subtype: MediaSubtype = [], uniformTypeIdentifier: String,
                isGalleryContent: Bool = true) {
        self.kind = kind
        self.subtype = subtype
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.isGalleryContent = isGalleryContent
    }

    public static let notMedia = Classification(kind: .unknown, subtype: [],
                                                uniformTypeIdentifier: "", isGalleryContent: false)
}

public enum MediaTypeRules {
    /// Classify one file.
    ///
    /// The extension decides *whether* it is gallery content and the declared type decides *what* it is,
    /// because those two only disagree in one direction that matters: a `.txt` renamed to `.jpg` should
    /// not become a photo, and a `.CR2` that LaunchServices resolves to `public.data` is still a photo.
    public static func classify(name: String, fileExtension: String, contentType: UTType?) -> Classification {
        let ext = fileExtension.lowercased()
        guard SkipRules.isMediaExtension(ext) else { return .notMedia }

        let identifier = contentType?.identifier ?? ""
        let declaresImage = contentType?.conforms(to: .image) == true
        let declaresVideo = contentType?.conforms(to: .movie) == true
            || contentType?.conforms(to: .audiovisualContent) == true

        // `public.data` and friends are LaunchServices for "I have no idea", which is why an unknown type
        // never overrules the extension the user can see. A *named* non-media type is a different answer:
        // a text file renamed to `.jpg` is a lie about the file, not a gap in the type database.
        if let contentType, !declaresImage, !declaresVideo, !isUninformative(contentType) {
            return .notMedia
        }

        var subtype: MediaSubtype = []
        if ext == "heic" || ext == "heif" || ext == "hif"
            || identifier.hasPrefix("public.heic") || identifier.hasPrefix("public.heif") {
            subtype.insert(.heic)
        }
        if rawExtensions.contains(ext) || identifier.hasPrefix("com.apple.raw-format")
            || identifier == "public.raw-image" {
            subtype.insert(.raw)
        }
        if ext == "gif" || identifier == "com.compuserve.gif" {
            subtype.insert(.gif)
            // A GIF is animated until proven otherwise; pass B can demote a single-frame one, and being
            // wrong here only puts a still in the Animated album.
            subtype.insert(.animated)
        }
        if ext == "tif" || ext == "tiff" || identifier == "public.tiff" { subtype.insert(.tiff) }
        if isScreenshot(name: name, extension: ext, identifier: identifier) { subtype.insert(.screenshot) }

        let kind: MediaKind
        if rawExtensions.contains(ext) {
            // A RAW container holds a still first and, for Canon's Dual Pixel RAW and friends, a short
            // clip second. Trusting a declared type that claims footage would file a photograph under
            // Videos, so the extension wins for the formats where both are possible.
            kind = .image
        } else if declaresImage != declaresVideo {
            kind = declaresVideo ? .video : .image
        } else {
            // Neither, or both: the extension is the user's own claim about the file.
            kind = SkipRules.videoExtensions.contains(ext) && !SkipRules.imageExtensions.contains(ext)
                ? .video : .image
        }

        return Classification(
            kind: kind,
            subtype: subtype,
            uniformTypeIdentifier: identifier.isEmpty ? fallbackUTI(extension: ext, kind: kind) : identifier
        )
    }

    /// Screenshots are a heuristic, never a fact: filename, UTI, or the Capture-service naming. A wrong
    /// guess costs one reclassification query, which is why it is a subtype bit and not a separate table.
    public static func isScreenshot(name: String, extension ext: String, identifier: String) -> Bool {
        if identifier == "com.apple.screenshot" || identifier == "com.apple.screenimage"
            || identifier == "com.apple.screencapture" || identifier == "com.apple.screencapturetiff" {
            return true
        }
        let lowered = name.lowercased()
        return lowered.hasPrefix("screenshot") || lowered.hasPrefix("screen-capture")
            || lowered.hasPrefix("screen capture") || lowered.hasPrefix("capture-")
            || lowered.hasPrefix("cleanshot") || lowered.hasPrefix("snagit")
            || lowered.hasPrefix("simulator-screenshot")
    }

    /// The type identifiers that mean the filesystem declined to answer rather than "this is not a
    /// picture". They are why a RAW file on an SMB share, where LaunchServices has never looked, still
    /// becomes a row.
    static let uninformativeIdentifiers: Set<String> = [
        "public.item", "public.content", "public.data", "public.directory", "public.folder",
    ]

    static func isUninformative(_ type: UTType) -> Bool {
        uninformativeIdentifiers.contains(type.identifier)
    }

    static let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "nrw", "dng", "orf", "ori", "rw2", "raf", "sr2", "srf", "srw",
        "arw", "sff", "pef", "ptx", "rwl", "3fr", "fff", "iiq", "eip", "mef", "mos", "x3f", "dcr",
        "kdc", "wdp", "hdp", "jxr",
    ]

    private static func fallbackUTI(extension ext: String, kind: MediaKind) -> String {
        switch (kind, ext) {
        case (.image, "jpg"), (.image, "jpeg"), (.image, "jpe"), (.image, "jfif"): "public.jpeg"
        case (.image, "png"): "public.png"
        case (.image, "heic"): "public.heic"
        case (.image, "heif"), (.image, "hif"): "public.heif"
        case (.image, "gif"): "com.compuserve.gif"
        case (.image, "tif"), (.image, "tiff"): "public.tiff"
        case (.image, "webp"): "org.webmproject.webp"
        case (.image, _): "public.image"
        case (.video, "mov"), (.video, "qt"): "com.apple.quicktime-movie"
        case (.video, "mp4"), (.video, "m4v"): "public.mpeg-4"
        case (.video, _): "public.movie"
        // Unreachable from `classify`, which never produces `.unknown` — but the compiler cannot see that,
        // and a wrong guess here is a bad UTI string rather than a mis-filed row.
        case (.unknown, _): "public.data"
        }
    }

    /// Live Photos are two files with the same stem, and a pair is only visible inside one directory.
    ///
    /// The MOV half is flagged rather than dropped: the file exists and the user is entitled to see it
    /// accounted for, but it must not appear as a second entry in "Videos". Two seconds is the window
    /// Apple's own pairing allows for the capture-date skew between the still and its clip.
    public static func markLivePhotoPairs(_ entries: inout [ScannedEntry], pairingWindow: TimeInterval = 2) {
        var imageIndexesByStem: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() where entry.kind == .image {
            imageIndexesByStem[stem(entry.name), default: []].append(index)
        }
        guard !imageIndexesByStem.isEmpty else { return }

        for (index, entry) in entries.enumerated() where entry.kind == .video {
            guard let candidates = imageIndexesByStem[stem(entry.name)],
                  let videoDate = entry.modificationDate else { continue }
            let matched = candidates.first {
                guard let imageDate = entries[$0].modificationDate else { return false }
                return abs(videoDate.timeIntervalSince(imageDate)) <= pairingWindow
            }
            guard let matched else { continue }
            entries[index].subtype.insert(.livePhotoCompanion)
            entries[matched].subtype.insert(.livePhoto)
        }
    }

    /// Base name without its extension, lowercased — `IMG_1234.HEIC` and `IMG_1234.MOV` is one moment.
    static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name.lowercased() }
        return String(name[..<dot]).lowercased()
    }
}
