import Foundation
import GalleryDomain
import GalleryImaging

/// What a decoded file turns a pass-A row into.
///
/// Pure functions on a row, kept out of the worker so the opinions that decide what a user sees — which day
/// a photo belongs to, whether it counts as a panorama, what the search box can match — are testable without
/// a disk, a lane, or a real ImageIO decode.
enum MetadataRules {
    /// The row after a successful read.
    ///
    /// Every field is `metadata ?? row`, not `metadata`: a decoder that found no colour space must not erase
    /// the one an earlier attempt read, and a re-scan of a file whose header has since become unreadable
    /// still has to answer with what the catalog knows. `stage` and `error` are the caller's business — they
    /// depend on whether a poster was written, which is not a fact about the metadata.
    static func refine(_ row: MediaItem, from metadata: FileMetadata, zone: TimeZone) -> MediaItem {
        var item = row
        if let type = metadata.typeIdentifier, !type.isEmpty { item.uniformTypeIdentifier = type }
        item.pixelSize = metadata.pixelSize ?? row.pixelSize
        item.orientation = metadata.orientation ?? row.orientation
        item.colorSpace = metadata.colorSpace ?? row.colorSpace
        item.durationMicroseconds = metadata.durationMicroseconds ?? row.durationMicroseconds
        item.codec = metadata.codec ?? row.codec
        item.device = metadata.device ?? row.device
        item.lens = metadata.lens ?? row.lens
        item.gps = metadata.gps ?? row.gps
        item.capture = CaptureDateResolver.resolve(dates: metadata.dates,
                                                   modificationDate: row.modificationDate,
                                                   creationDate: row.creationDate,
                                                   assumedZone: zone) ?? row.capture
        // A RAW container that decodes is a photograph whatever LaunchServices said, and the alternative —
        // trusting a declared type that claims footage — files Canon's Dual Pixel clips under Videos.
        if metadata.isRaw { item.kind = .image }
        item.subtype = refinedSubtype(of: row, metadata)
        item.searchText = searchText(kind: item.kind, subtype: item.subtype, codec: item.codec,
                                     colorSpace: item.colorSpace)
        // Deliberate exception to the `?? row` rule every other field follows: the title is authored by us
        // and written into the file, so the file is the whole truth. A fallback to the row's old value would
        // make a cleared title impossible to represent for the rest of the file's life.
        item.title = metadata.title
        return item
    }

    /// The row after a read that produced nothing: the badge changes, the knowledge does not.
    static func unreadable(_ row: MediaItem, _ error: IndexError) -> MediaItem {
        var item = row
        item.error = error
        return item
    }

    /// Pass A's guess about the extension, corrected by what the file turned out to be.
    ///
    /// The bits only a decode can settle are the frame count and the real container type. `screenshot`,
    /// `livePhoto` and `livePhotoCompanion` deliberately pass through untouched: they come from the filename
    /// and from pairing, and no header disagrees with them.
    static func refinedSubtype(of row: MediaItem, _ metadata: FileMetadata) -> MediaSubtype {
        var subtype = row.subtype
        if metadata.isRaw { subtype.insert(.raw) }
        // A GIF is "animated until proven otherwise" in pass A, and the frame count is the proof. The other
        // containers get the same test: a burst-mode HEIC has frames too, and belongs in the Animated album.
        if metadata.frameCount > 1 { subtype.insert(.animated) } else { subtype.remove(.animated) }
        if let type = metadata.typeIdentifier {
            if type.hasPrefix("public.heic") || type.hasPrefix("public.heif") { subtype.insert(.heic) }
            if type == "public.tiff" { subtype.insert(.tiff) }
            if type == "com.compuserve.gif" { subtype.insert(.gif) }
        }
        if isPanorama(metadata.pixelSize) { subtype.insert(.panorama) }
        return subtype
    }

    /// A stitched shot rather than a wide crop: the phone's widest panorama ships at ~11k px on the long
    /// side, and nothing else a camera writes is both that long *and* that flat — a 4K frame is 1.78:1.
    static func isPanorama(_ size: PixelSize?) -> Bool {
        guard let size, size.longSide >= 8_000 else { return false }
        let short = max(1, min(size.width, size.height))
        return Double(size.longSide) / Double(short) >= 2
    }

    /// The vocabulary the search box gets beyond what `media_fts` already indexes by column — name, place,
    /// device, lens.
    ///
    /// A closed list rather than a dump of the EXIF: matching "1/125" or "sRGB" is noise a user never types
    /// on purpose, and every word here is one they do. Live Text arrives in a later milestone and lands in
    /// this column, which is why it is a string rather than another set of bits.
    static func searchText(kind: MediaKind, subtype: MediaSubtype, codec: String?,
                           colorSpace: String?) -> String {
        var words: [String] = [kind == .video ? "video" : "photo"]
        if subtype.contains(.raw) { words.append("raw") }
        if subtype.contains(.heic) { words.append("heic") }
        if subtype.contains(.tiff) { words.append("tiff") }
        if subtype.contains(.gif) { words.append("gif") }
        if subtype.contains(.animated) { words.append("animated") }
        if subtype.contains(.screenshot) { words.append("screenshot") }
        if subtype.contains(.livePhoto) { words.append("live photo") }
        if subtype.contains(.panorama) { words.append("panorama") }
        if subtype.contains(.hdr) { words.append("hdr") }
        if let codec, !codec.isEmpty { words.append(codec) }
        if let colorSpace, !colorSpace.isEmpty { words.append(colorSpace) }
        return words.joined(separator: " ")
    }
}
