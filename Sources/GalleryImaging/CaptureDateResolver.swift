import Foundation
import GalleryDomain

/// The capture-date ladder, and the only place in the app that turns metadata into "what day this is".
///
/// Order matters more than it looks: `OffsetTimeOriginal` is the one field that survives a flight, so it
/// outranks everything; a bare `DateTimeOriginal` is a wall clock with no zone and gets guessed at; the
/// filesystem date is last because a copied file's mtime is a lie the day albums would rather not tell.
/// Each rung is recorded in `cap_src`, so a later correction can tell a real reading from an assumption.
public enum CaptureDateResolver {
    /// EXIF wall clocks, parsed as if UTC — see `CaptureMoment.resolving` for what that means.
    public static func parseWallClock(_ string: String) -> Date? {
        let normalized = standardizing(string)
        for format in wallClockFormats {
            let formatter = makeFormatter(format)
            if let date = formatter.date(from: normalized) { return date }
        }
        return nil
    }

    /// `+09:00`, `-0530`, `+09`, `Z`, and the empty string a file writes when the camera knew but said
    /// nothing. Anything else is not an offset, and reading it as one would shift a photo by hours.
    public static func parseOffset(_ string: String?) -> Int? {
        guard var text = string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.uppercased() == "Z" { return 0 }
        guard let first = text.first, first == "+" || first == "-" else { return nil }
        let sign = first == "-" ? -1 : 1
        text.removeFirst()
        let digits = text.filter(\.isNumber)
        switch digits.count {
        case 0: return nil
        case 2: return sign * Int(digits)! * 3600
        case 4: return sign * (Int(digits.prefix(2))! * 3600 + Int(digits.suffix(2))! * 60)
        default: return nil
        }
    }

    /// `.123` and `123` both appear in the wild; a half-second is worth keeping because burst frames differ
    /// by less than a second and the sort must not collapse them into one arbitrary order.
    public static func parseSubsecond(_ string: String?) -> Double? {
        guard let text = string?.trimmingCharacters(in: CharacterSet(charactersIn: " .")),
              !text.isEmpty,
              text.allSatisfy(\.isNumber),
              let value = Double("0.\(text)") else { return nil }
        return min(0.999999, value)
    }

    /// The ladder itself. `modificationDate` and `creationDate` are the file's own stat dates, which is the
    /// last rung before "we do not know".
    public static func resolve(
        dates: ExifDates,
        modificationDate: Date?,
        creationDate: Date? = nil,
        assumedZone: TimeZone = .current
    ) -> CaptureMoment? {
        if let original = plausible(dates.dateTimeOriginal) {
            let subsecond = parseSubsecond(dates.subsecTimeOriginal) ?? 0
            if let offset = parseOffset(dates.offsetTimeOriginal) {
                return CaptureMoment.resolving(
                    wallClock: original.addingTimeInterval(subsecond),
                    offsetSeconds: offset,
                    assumedZone: assumedZone,
                    source: .exifOffsetTimeOriginal
                )
            }
            return CaptureMoment.resolving(
                wallClock: original.addingTimeInterval(subsecond),
                offsetSeconds: nil,
                assumedZone: assumedZone,
                source: .exifDateTimeOriginal
            )
        }
        if let digitized = plausible(dates.dateTimeDigitized) {
            return CaptureMoment.resolving(
                wallClock: digitized,
                offsetSeconds: parseOffset(dates.offsetTimeDigitized),
                assumedZone: assumedZone,
                source: .exifDateTimeDigitized
            )
        }
        if let created = dates.assetCreationDate, isSane(created) {
            return CaptureMoment(instant: created, wallClock: created, timeZone: assumedZone,
                                 source: .assetCreationDate)
        }
        if let stamp = modificationDate ?? creationDate, isSane(stamp) {
            return CaptureMoment(instant: stamp, wallClock: stamp, timeZone: assumedZone,
                                 source: .fileSystem)
        }
        return nil
    }

    /// A date the camera could not have taken is treated as no date at all: `0000:00:00` parses as
    /// 1 BC on some stacks, and a 1904 or 2040 stamp is usually a dead clock battery rather than history.
    private static func plausible(_ string: String?) -> Date? {
        guard let string, let date = parseWallClock(string), isSane(date) else { return nil }
        return date
    }

    private static func isSane(_ date: Date) -> Bool {
        date.timeIntervalSince1970 > 0 && date.timeIntervalSince1970 < 4_102_444_800  // year 2100
    }

    private static let wallClockFormats = [
        "yyyy:MM:dd HH:mm:ss",
        "yyyy:MM:dd HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy:MM:dd",
        "yyyy-MM-dd",
    ]

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = CaptureMoment.utc
        formatter.dateFormat = format
        return formatter
    }

    /// Some cameras write a `T` separator or a `_` where the date and time meet, and some leave a trailing
    /// `Z`. Normalizing beats a formatter per camera vendor.
    private static func standardizing(_ string: String) -> String {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("Z") { text = String(text.dropLast()) }
        return text
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
