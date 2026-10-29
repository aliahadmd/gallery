import Foundation
import GalleryDomain

/// The date strings a file carries, exactly as they arrived.
///
/// Parsing is deliberately left to `CaptureDateResolver`: a reader that guessed would make the ladder
/// untestable without a box of real camera files, and the ladder is the one part of this app where a
/// plausible-looking wrong answer is worse than an obvious missing one.
public struct ExifDates: Sendable, Hashable {
    /// Exif `DateTimeOriginal` — "2024:05:03 14:22:01", the moment the shutter opened.
    public var dateTimeOriginal: String?
    /// Exif `SubsecTimeOriginal` — the fraction, with or without its leading dot.
    public var subsecTimeOriginal: String?
    /// Exif `OffsetTimeOriginal` — "+09:00". The only field that says which zone the digits mean.
    public var offsetTimeOriginal: String?
    /// Exif `DateTimeDigitized`, or the TIFF `DateTime` an editor writes when there is nothing better.
    public var dateTimeDigitized: String?
    public var offsetTimeDigitized: String?
    /// Already an absolute date: AVFoundation hands a movie's creation date back as a `Date`, not a string.
    public var assetCreationDate: Date?

    public init(
        dateTimeOriginal: String? = nil,
        subsecTimeOriginal: String? = nil,
        offsetTimeOriginal: String? = nil,
        dateTimeDigitized: String? = nil,
        offsetTimeDigitized: String? = nil,
        assetCreationDate: Date? = nil
    ) {
        self.dateTimeOriginal = dateTimeOriginal
        self.subsecTimeOriginal = subsecTimeOriginal
        self.offsetTimeOriginal = offsetTimeOriginal
        self.dateTimeDigitized = dateTimeDigitized
        self.offsetTimeDigitized = offsetTimeDigitized
        self.assetCreationDate = assetCreationDate
    }

    public static let none = ExifDates()

    public var isEmpty: Bool {
        dateTimeOriginal == nil && dateTimeDigitized == nil && assetCreationDate == nil
    }
}

/// What one decode produced for one file — enough to fill the catalog's metadata columns.
public struct FileMetadata: Sendable, Hashable {
    public var typeIdentifier: String?
    public var pixelSize: PixelSize?
    public var orientation: Int16?
    public var colorSpace: String?
    /// `CGImageSourceGetCount`: more than one frame means an animated container, not a still.
    public var frameCount: Int
    /// TIFF `XResolution`, which is 72 for a camera file and 144 for a macOS screenshot.
    public var dpiWidth: Double?
    public var device: String?
    public var lens: String?
    public var gps: GPSPoint?
    public var durationMicroseconds: Int64?
    public var codec: String?
    public var isRaw: Bool
    public var dates: ExifDates
    /// IPTC `ObjectName`, trimmed; nil when the file carries no title. Not defaulted to the filename — the
    /// catalog stores what the file says, and the UI falls back to the name when it is nil.
    public var title: String?

    public init(
        typeIdentifier: String? = nil,
        pixelSize: PixelSize? = nil,
        orientation: Int16? = nil,
        colorSpace: String? = nil,
        frameCount: Int = 1,
        dpiWidth: Double? = nil,
        device: String? = nil,
        lens: String? = nil,
        gps: GPSPoint? = nil,
        durationMicroseconds: Int64? = nil,
        codec: String? = nil,
        isRaw: Bool = false,
        dates: ExifDates = .none,
        title: String? = nil
    ) {
        self.typeIdentifier = typeIdentifier
        self.pixelSize = pixelSize
        self.orientation = orientation
        self.colorSpace = colorSpace
        self.frameCount = frameCount
        self.dpiWidth = dpiWidth
        self.device = device
        self.lens = lens
        self.gps = gps
        self.durationMicroseconds = durationMicroseconds
        self.codec = codec
        self.isRaw = isRaw
        self.dates = dates
        self.title = title
    }

    public static let empty = FileMetadata()
}

/// A decode either produced something or says which per-file error the row should carry. The failure type
/// is the catalog's own `IndexError` because that is where the value ends up: a distinct error enum here
/// would need a mapping table that can only drift.
public enum ReadOutcome: Sendable, Hashable {
    case decoded(FileMetadata)
    case failed(IndexError)
}

/// One still read for both of pass B's answers: what the file is, and the small picture to draw it with.
///
/// The poster is optional because the two questions have different failure modes: a RAW file whose header
/// ImageIO can parse but whose pixels it cannot is a photo with a real capture date and GPS and no preview,
/// which is a row worth keeping rather than an error.
public enum StillDecodeOutcome: Sendable, Hashable {
    case decoded(metadata: FileMetadata, poster: Data?)
    case failed(IndexError)
}
