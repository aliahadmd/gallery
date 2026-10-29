import Foundation
import CoreServices
import ImageIO
import UniformTypeIdentifiers
import GalleryDomain

/// Reads an image's properties with ImageIO — no pixels, no scaling, one pass.
///
/// `kCGImageSourceShouldCache: false` is the whole point: ImageIO's own cache would hold decoded bitmaps
/// for every file pass B touches, which is exactly the memory this app cannot spend on a 100k library.
/// The pixel dimensions and orientation come out of the header, so a 48 MP HEIC costs the same here as a
/// thumbnail. `decode(_:posterIn:)` is the one path that does ask for pixels, downsampled during the same
/// open rather than in a second pass over the file.
public enum ImageMetadataReader {
    public static func read(at url: URL) -> ReadOutcome {
        switch open(url) {
        case .failure(let error): .failed(error)
        case .success(let source, let properties): .decoded(metadata(source, properties))
        }
    }

    /// Properties *and* a bucket-sized poster out of one open of the file.
    ///
    /// Pass B asks both questions about the same picture, and asking them separately decodes a 48 MP HEIC
    /// twice to answer one the header had already settled. The poster is cut from the same `CGImageSource`,
    /// so ImageIO's downsampled decode does the work once — which is the difference between an hour and two
    /// on a 100k library, and between one working set and two.
    public static func decode(_ url: URL, posterIn bucket: ThumbnailBucket) -> StillDecodeOutcome {
        switch open(url) {
        case .failure(let error): .failed(error)
        case .success(let source, let properties):
            .decoded(metadata: metadata(source, properties),
                     poster: ThumbnailBaker.thumbnail(source, bucket).flatMap { ThumbnailBaker.jpeg($0) })
        }
    }

    /// The file opened and its header parsed, or the one `IndexError` that says why not.
    private enum Opened {
        case failure(IndexError)
        case success(CGImageSource, [CFString: Any])
    }

    private static func open(_ url: URL) -> Opened {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.vanished) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .failure(.noAccess) }
        // A file with no bytes is damage whatever it was going to be — a download that stopped at zero, an
        // iCloud stub that never filled in. ImageIO refuses even to make a source out of one, and its answer
        // ("a format we do not know") is the wrong advice for a picture whose contents simply are not there.
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 > 0 else {
            return .failure(.corrupt)
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return .failure(.undecodable)
        }
        // A header ImageIO recognised but could not parse is a damaged file, not an unsupported one —
        // the distinction is what tells the user to re-download rather than to convert.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return .failure(.corrupt)
        }
        return .success(source, properties)
    }

    private static func metadata(_ source: CGImageSource, _ properties: [CFString: Any]) -> FileMetadata {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        var metadata = FileMetadata()
        metadata.typeIdentifier = CGImageSourceGetType(source) as String?
        metadata.pixelSize = pixelSize(properties)
        metadata.orientation = orientation(properties)
        metadata.colorSpace = colorSpace(properties)
        metadata.frameCount = CGImageSourceGetCount(source)
        metadata.dpiWidth = number(tiff[kCGImagePropertyTIFFXResolution])
        let title = text(iptc[kCGImagePropertyIPTCObjectName])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = (title?.isEmpty ?? true) ? nil : title
        metadata.device = device(tiff: tiff, exif: exif)
        metadata.lens = text(exif[kCGImagePropertyExifLensModel]) ?? text(aux[kCGImagePropertyExifAuxLensModel])
        metadata.gps = gps(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        metadata.isRaw = metadata.typeIdentifier.map(isRaw) ?? false
        metadata.dates = dates(exif: exif, tiff: tiff)
        return metadata
    }

    private static func dates(exif: [CFString: Any], tiff: [CFString: Any]) -> ExifDates {
        ExifDates(
            dateTimeOriginal: text(exif[kCGImagePropertyExifDateTimeOriginal]),
            subsecTimeOriginal: text(exif[kCGImagePropertyExifSubsecTimeOriginal]),
            offsetTimeOriginal: text(exif[kCGImagePropertyExifOffsetTimeOriginal]),
            // `DateTimeDigitized` exists in both dictionaries; Exif wins because a camera writes the
            // transfer-time-corrected value there, and TIFF's `DateTime` is the one an editor overwrites.
            dateTimeDigitized: text(exif[kCGImagePropertyExifDateTimeDigitized])
                ?? text(tiff[kCGImagePropertyTIFFDateTime]),
            offsetTimeDigitized: text(exif[kCGImagePropertyExifOffsetTimeDigitized])
        )
    }

    private static func pixelSize(_ properties: [CFString: Any]) -> PixelSize? {
        guard let width = number(properties[kCGImagePropertyPixelWidth]),
              let height = number(properties[kCGImagePropertyPixelHeight]),
              width > 0, height > 0 else { return nil }
        return PixelSize(width: Int32(width), height: Int32(height))
    }

    private static func orientation(_ properties: [CFString: Any]) -> Int16? {
        guard let raw = number(properties[kCGImagePropertyOrientation]), (1...8).contains(Int(raw)) else {
            return nil
        }
        return Int16(raw)
    }

    private static func colorSpace(_ properties: [CFString: Any]) -> String? {
        text(properties[kCGImagePropertyProfileName]) ?? text(properties[kCGImagePropertyColorModel])
    }

    private static func device(tiff: [CFString: Any], exif: [CFString: Any]) -> String? {
        let make = text(tiff[kCGImagePropertyTIFFMake])
        let model = text(tiff[kCGImagePropertyTIFFModel])
        let joined = [make, model].compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// `kCGImagePropertyGPSLatitude` is documented as a rational triple, and in practice arrives as either
    /// a single decimal `Double` or an array of three, depending on the container that wrote it. Accepting
    /// only one of the two silently drops the GPS of every camera in the other group — and a photo with no
    /// coordinates is a photo that never reaches a location album.
    private static func gps(_ dictionary: [CFString: Any]?) -> GPSPoint? {
        guard let dictionary else { return nil }
        guard var latitude = decimal(dictionary[kCGImagePropertyGPSLatitude],
                                      sign: dictionary[kCGImagePropertyGPSLatitudeRef]),
              var longitude = decimal(dictionary[kCGImagePropertyGPSLongitude],
                                       sign: dictionary[kCGImagePropertyGPSLongitudeRef]) else { return nil }
        if latitude == 0 && longitude == 0 { return nil }
        // A `Ref` of S or W is the sign; some stacks apply it, some leave it to the reader.
        if isNegative(dictionary[kCGImagePropertyGPSLatitudeRef]) { latitude = -abs(latitude) }
        if isNegative(dictionary[kCGImagePropertyGPSLongitudeRef]) { longitude = -abs(longitude) }

        var point = GPSPoint(latitude: latitude, longitude: longitude)
        point.altitude = altitude(dictionary)
        point.speedMetersPerSecond = speed(dictionary)
        point.direction = number(dictionary[kCGImagePropertyGPSImgDirection])
        point.timestamp = fixDate(dictionary)
        return point.isValid ? point : nil
    }

    /// A GPS fix carries its own UTC clock, split across two keys. It is not the capture date — a phone
    /// that has been off for a week stamps the fix with the last time it knew — so it is stored beside the
    /// coordinates rather than being allowed to outrank the ladder.
    private static func fixDate(_ dictionary: [CFString: Any]) -> Date? {
        guard let stamp = text(dictionary[kCGImagePropertyGPSDateStamp]) else { return nil }
        let time = text(dictionary[kCGImagePropertyGPSTimeStamp]) ?? "00:00:00"
        return CaptureDateResolver.parseWallClock("\(stamp) \(time)")
    }

    private static func altitude(_ dictionary: [CFString: Any]) -> Double? {
        guard let value = number(dictionary[kCGImagePropertyGPSAltitude]) else { return nil }
        // `GPSAltitudeRef` is 0 for above sea level and 1 for below, which is a sign, not a unit.
        let below = dictionary[kCGImagePropertyGPSAltitudeRef].map { number($0) ?? 0 } ?? 0
        return below >= 1 ? -abs(value) : value
    }

    private static func speed(_ dictionary: [CFString: Any]) -> Double? {
        guard let value = number(dictionary[kCGImagePropertyGPSSpeed]) else { return nil }
        // The reference says km/h or knots; the catalog column is metres per second.
        switch dictionary[kCGImagePropertyGPSSpeedRef].flatMap(text)?.uppercased() {
        case "N": return value * 0.514444
        case "M": return value * 0.44704
        default: return value / 3.6
        }
    }

    private static func decimal(_ value: Any?, sign: Any?) -> Double? {
        if let single = number(value) { return abs(single) }
        guard let parts = value as? [Any] else { return nil }
        let components = parts.compactMap { number($0) }
        guard components.count == 3 else { return nil }
        return abs(components[0]) + components[1] / 60 + components[2] / 3600
    }

    private static func isNegative(_ value: Any?) -> Bool {
        switch text(value)?.uppercased() {
        case "S", "W": true
        default: false
        }
    }

    /// RAW is a conformance test, not an extension list: a `.DNG` from one camera and a `.CR3` from
    /// another share a public parent, and ImageIO is the only party that knows which ones it can read.
    private static func isRaw(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
