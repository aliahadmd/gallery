import Foundation
import GalleryDomain

/// One field's instruction: leave it, remove it, or write this.
public enum FieldEdit<T: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    case unchanged
    case clear
    case set(T)

    public var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

public struct CaptureEdit: Sendable, Hashable, Codable {
    public var instant: Date
    /// Nil means the offset could not be known; EXIF then stores only the wall clock.
    public var offsetSeconds: Int?

    public init(instant: Date, offsetSeconds: Int? = nil) {
        self.instant = instant
        self.offsetSeconds = offsetSeconds
    }
}

public struct MetadataOverrides: Sendable, Hashable, Codable {
    public var title: FieldEdit<String>
    public var capture: FieldEdit<CaptureEdit>
    public var gps: FieldEdit<GPSPoint>

    public init(
        title: FieldEdit<String> = .unchanged,
        capture: FieldEdit<CaptureEdit> = .unchanged,
        gps: FieldEdit<GPSPoint> = .unchanged
    ) {
        self.title = title
        self.capture = capture
        self.gps = gps
    }

    public var isEmpty: Bool {
        title.isUnchanged && capture.isUnchanged && gps.isUnchanged
    }
}

/// The fields a file already carries, read before an edit and written back after it. The read-back uses
/// the same type, which is what makes "written" and "dropped" distinguishable.
public struct ExistingMetadata: Sendable, Hashable {
    public var title: String?
    public var captureInstant: Date?
    public var offsetSeconds: Int?
    public var gps: GPSPoint?

    public init(
        title: String? = nil, captureInstant: Date? = nil, offsetSeconds: Int? = nil,
        gps: GPSPoint? = nil
    ) {
        self.title = title
        self.captureInstant = captureInstant
        self.offsetSeconds = offsetSeconds
        self.gps = gps
    }

    public static let none = ExistingMetadata()
}

/// What the file should carry after the edit — the single pure place the overrides become values.
public struct MetadataValues: Sendable, Hashable {
    public var title: String?
    public var capture: CaptureEdit?
    public var gps: GPSPoint?

    public static func resolve(
        _ overrides: MetadataOverrides, existing: ExistingMetadata
    ) -> MetadataValues {
        var values = MetadataValues()
        switch overrides.title {
        case .unchanged:
            values.title = existing.title
        case .clear:
            values.title = nil
        case .set(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            values.title = trimmed.isEmpty ? nil : trimmed
        }
        switch overrides.capture {
        case .unchanged:
            values.capture = existing.captureInstant.map {
                CaptureEdit(instant: $0, offsetSeconds: existing.offsetSeconds)
            }
        case .clear:
            values.capture = nil
        case .set(let edit):
            values.capture = edit
        }
        switch overrides.gps {
        case .unchanged:
            values.gps = existing.gps
        case .clear:
            values.gps = nil
        case .set(let point):
            values.gps = point
        }
        return values
    }
}

/// EXIF's two date fields: the digits are wall-clock in the capture zone, and `OffsetTimeOriginal` is the
/// only thing that says which zone. `yyyy:MM:dd HH:mm:ss`, `en_US_POSIX`, as `CaptureDateResolver` parses.
public enum ExifOffset {
    public static func format(_ seconds: Int) -> String {
        if seconds == 0 { return "Z" }
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d:%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    public static func dateTime(_ date: Date, offsetSeconds: Int?) -> (date: String, subsecond: String?) {
        let zone = offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let fraction = date.timeIntervalSince1970 - floor(date.timeIntervalSince1970)
        let millis = Int((fraction * 1000).rounded())
        return (formatter.string(from: date), millis == 0 ? nil : String(format: "%03d", millis))
    }
}
