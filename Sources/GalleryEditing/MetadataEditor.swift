import CoreGraphics
import Foundation
import ImageIO
import GalleryDomain

public enum MetadataWriteResult: Sendable, Hashable {
    case written(reencoded: Bool)
    /// The container accepted the write but lost the field on read-back — a format that cannot store it.
    case dropped(field: String)
    case failed
}

/// Metadata-only edits, without re-encoding the pixels.
///
/// `CGImageDestinationCopyImageSource` copies the compressed stream and merges an edited metadata object on
/// top: no generation loss, maker notes and private blocks survive, and a 48 MP file is edited in
/// milliseconds. A container ImageIO cannot open a metadata object for falls back to a full re-encode, which
/// is flagged so the caller can say so.
public enum MetadataEditor {
    public static func rewrite(
        _ url: URL,
        overrides: MetadataOverrides,
        existing: ExistingMetadata,
        to destination: URL
    ) -> MetadataWriteResult {
        let values = MetadataValues.resolve(overrides, existing: existing)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .failed }
        // `CopyImageSource` merges an edited metadata object over the source's; merge cannot *remove* a tag
        // (an absent tag means "keep", and a null is stored as a value). A clear therefore takes the
        // re-encode path, which is the one case where losing maker notes buys the user what they asked for.
        let needsRemoval = (overrides.title == FieldEdit<String>.clear && existing.title != nil)
            || (overrides.capture == FieldEdit<CaptureEdit>.clear && existing.captureInstant != nil)
            || (overrides.gps == FieldEdit<GPSPoint>.clear && existing.gps != nil)
        if needsRemoval {
            return reencode(url, source: source, values: values, overrides: overrides, to: destination)
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let mutable = CGImageMetadataCreateMutableCopy(metadata) ?? CGImageMetadataCreateMutable()
            apply(values, to: mutable)
            guard let type = CGImageSourceGetType(source),
                  let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
                return .failed
            }
            var error: Unmanaged<CFError>?
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: mutable,
                kCGImageDestinationMergeMetadata: true,
            ]
            let copied = CGImageDestinationCopyImageSource(
                output, source, options as CFDictionary, &error
            )
            guard copied, error == nil else { return .failed }
            return verify(values, overrides, at: destination, reencoded: false)
        }
        return reencode(url, source: source, values: values, overrides: overrides, to: destination)
    }

    /// The fields the file carries now, for the editor's form and for the projection after a write.
    public static func readBack(_ url: URL) -> ExistingMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        var result = ExistingMetadata()
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if let title = iptc[kCGImagePropertyIPTCObjectName] as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.title = trimmed.isEmpty ? nil : trimmed
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let offsetText = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            result.offsetSeconds = ExifOffsetSeconds.parse(offsetText)
            result.captureInstant = parseExifDate(
                text,
                offsetSeconds: result.offsetSeconds,
                subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String
            )
        }
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        if let latitude = number(gps[kCGImagePropertyGPSLatitude]),
           let longitude = number(gps[kCGImagePropertyGPSLongitude]) {
            let latitudeSign = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" ? -1 : 1
            let longitudeSign = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" ? -1 : 1
            result.gps = GPSPoint(
                latitude: latitude * Double(latitudeSign),
                longitude: longitude * Double(longitudeSign),
                altitude: number(gps[kCGImagePropertyGPSAltitude])
            )
        }
        return result
    }

    // MARK: - Writing into a metadata object

    private static func apply(_ values: MetadataValues, to metadata: CGMutableImageMetadata) {
        set(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName,
            values.title as CFString?)

        if let capture = values.capture {
            let formatted = ExifOffset.dateTime(capture.instant, offsetSeconds: capture.offsetSeconds)
            set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal,
                formatted.date as CFString)
            set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifSubsecTimeOriginal,
                formatted.subsecond as CFString?)
            set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal,
                capture.offsetSeconds.map(ExifOffset.format) as CFString?)
        } else {
            set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, nil)
            set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifSubsecTimeOriginal, nil)
            set(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal, nil)
        }

        if let gps = values.gps {
            set(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude,
                NSNumber(value: abs(gps.latitude)))
            set(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef,
                (gps.latitude < 0 ? "S" : "N") as CFString)
            set(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude,
                NSNumber(value: abs(gps.longitude)))
            set(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef,
                (gps.longitude < 0 ? "W" : "E") as CFString)
            if let altitude = gps.altitude {
                set(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitude,
                    NSNumber(value: abs(altitude)))
                set(metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSAltitudeRef,
                    NSNumber(value: altitude < 0 ? 1 : 0))
            }
        } else {
            for key in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                        kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef,
                        kCGImagePropertyGPSAltitude, kCGImagePropertyGPSAltitudeRef] {
                set(metadata, kCGImagePropertyGPSDictionary, key, nil)
            }
        }
    }

    /// Setting a value goes through the dictionary-aware API; removal goes through the path-aware one,
    /// because a null under `SetValueMatchingImageProperty` is a *value*, not a removal.
    private static func set(
        _ metadata: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString, _ value: CFTypeRef?
    ) {
        guard let value else {
            let path = removalPath(dictionary: dictionary, key: key) as CFString
            _ = CGImageMetadataRemoveTagWithPath(metadata, nil, path)
            _ = CGImageMetadataSetValueWithPath(metadata, nil, path, kCFNull)
            return
        }
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value)
    }

    private static func removalPath(dictionary: CFString, key: CFString) -> String {
        let prefix = switch dictionary {
        case kCGImagePropertyIPTCDictionary: "iptc"
        case kCGImagePropertyGPSDictionary: "gps"
        default: "exif"
        }
        let name = switch key {
        case kCGImagePropertyIPTCObjectName: "ObjectName"
        case kCGImagePropertyExifDateTimeOriginal: "DateTimeOriginal"
        case kCGImagePropertyExifSubsecTimeOriginal: "SubsecTimeOriginal"
        case kCGImagePropertyExifOffsetTimeOriginal: "OffsetTimeOriginal"
        case kCGImagePropertyGPSLatitude: "Latitude"
        case kCGImagePropertyGPSLatitudeRef: "LatitudeRef"
        case kCGImagePropertyGPSLongitude: "Longitude"
        case kCGImagePropertyGPSLongitudeRef: "LongitudeRef"
        case kCGImagePropertyGPSAltitude: "Altitude"
        case kCGImagePropertyGPSAltitudeRef: "AltitudeRef"
        default: key as String
        }
        return "\(prefix):\(name)"
    }

    // MARK: - Re-encode fallback

    private static func reencode(
        _ url: URL, source: CGImageSource, values: MetadataValues, overrides: MetadataOverrides,
        to destination: URL
    ) -> MetadataWriteResult {
        guard let kind = OutputFormats.kind(for: url),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let plan = EditPlanBuilder.plan(
                EditRecipe(), stored: PixelSize(width: Int32(image.width), height: Int32(image.height)),
                orientation: 1
              ) else {
            return .failed
        }
        var merged = MetadataPreserver.properties(from: properties, plan: plan)
        merge(values, into: &merged)
        let type = OutputFormats.utType(kind).identifier as CFString
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            return .failed
        }
        CGImageDestinationAddImage(output, image, merged as CFDictionary)
        guard CGImageDestinationFinalize(output) else { return .failed }
        return verify(values, overrides, at: destination, reencoded: true)
    }

    private static func merge(_ values: MetadataValues, into properties: inout [CFString: Any]) {
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if let title = values.title {
            iptc[kCGImagePropertyIPTCObjectName] = title
        } else {
            iptc.removeValue(forKey: kCGImagePropertyIPTCObjectName)
        }
        properties[kCGImagePropertyIPTCDictionary] = iptc

        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let capture = values.capture {
            let formatted = ExifOffset.dateTime(capture.instant, offsetSeconds: capture.offsetSeconds)
            exif[kCGImagePropertyExifDateTimeOriginal] = formatted.date
            exif[kCGImagePropertyExifSubsecTimeOriginal] = formatted.subsecond
            exif[kCGImagePropertyExifOffsetTimeOriginal] = capture.offsetSeconds.map(ExifOffset.format)
        } else {
            exif.removeValue(forKey: kCGImagePropertyExifDateTimeOriginal)
            exif.removeValue(forKey: kCGImagePropertyExifSubsecTimeOriginal)
            exif.removeValue(forKey: kCGImagePropertyExifOffsetTimeOriginal)
        }
        properties[kCGImagePropertyExifDictionary] = exif

        var gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        if let point = values.gps {
            gps[kCGImagePropertyGPSLatitude] = abs(point.latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = point.latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(point.longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = point.longitude < 0 ? "W" : "E"
            gps[kCGImagePropertyGPSAltitude] = point.altitude.map(abs)
            gps[kCGImagePropertyGPSAltitudeRef] = point.altitude.map { $0 < 0 ? 1 : 0 }
        } else {
            for key in [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef,
                        kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef,
                        kCGImagePropertyGPSAltitude, kCGImagePropertyGPSAltitudeRef] {
                gps.removeValue(forKey: key)
            }
        }
        properties[kCGImagePropertyGPSDictionary] = gps
    }

    // MARK: - Verification

    private static func verify(
        _ values: MetadataValues, _ overrides: MetadataOverrides, at url: URL, reencoded: Bool
    ) -> MetadataWriteResult {
        guard let read = readBack(url) else { return .failed }
        if !overrides.title.isUnchanged {
            let wanted = values.title
            if read.title != wanted { return .dropped(field: "title") }
        }
        if !overrides.capture.isUnchanged, let wanted = values.capture {
            guard let readDate = read.captureInstant else { return .dropped(field: "date") }
            if abs(readDate.timeIntervalSince(wanted.instant)) > 1 {
                return .dropped(field: "date")
            }
            if let offset = wanted.offsetSeconds, read.offsetSeconds != offset {
                return .dropped(field: "time zone")
            }
        }
        if !overrides.gps.isUnchanged {
            switch values.gps {
            case nil:
                if read.gps != nil { return .dropped(field: "location") }
            case .some(let wanted):
                guard let got = read.gps,
                      abs(got.latitude - wanted.latitude) < 1e-5,
                      abs(got.longitude - wanted.longitude) < 1e-5 else {
                    return .dropped(field: "location")
                }
            }
        }
        return .written(reencoded: reencoded)
    }

    private static func parseExifDate(
        _ text: String, offsetSeconds: Int?, subsecond: String?
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = offsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let base = formatter.date(from: text) else { return nil }
        guard let subsecond else { return base }
        let digits = subsecond.hasPrefix(".") ? String(subsecond.dropFirst()) : subsecond
        guard let fraction = Double("0." + digits) else { return base }
        return base.addingTimeInterval(fraction)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        return nil
    }
}

/// A tiny parser for `OffsetTimeOriginal`, matching `CaptureDateResolver` so the two cannot disagree.
private enum ExifOffsetSeconds {
    static func parse(_ text: String?) -> Int? {
        guard var value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.uppercased() == "Z" { return 0 }
        guard let first = value.first, first == "+" || first == "-" else { return nil }
        let sign = first == "-" ? -1 : 1
        value.removeFirst()
        let digits = value.filter(\.isNumber)
        switch digits.count {
        case 2: return sign * (Int(digits) ?? 0) * 3600
        case 4: return sign * ((Int(digits.prefix(2)) ?? 0) * 3600 + (Int(digits.suffix(2)) ?? 0) * 60)
        default: return nil
        }
    }
}
