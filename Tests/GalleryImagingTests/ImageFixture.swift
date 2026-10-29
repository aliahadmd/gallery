import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Writes real image files carrying the metadata dictionaries a camera would have written.
///
/// The capture-date ladder is the kind of code that passes every mock-based test and then fails on a
/// Saturday's worth of family photos, so these fixtures go through ImageIO's encoder and come back
/// through its reader: what is under test is the whole path, not our idea of what an Exif tag looks like.
struct ImageFixture {
    // MARK: - What to write

    var dateTimeOriginal: String?
    var subsecTimeOriginal: String?
    var offsetTimeOriginal: String?
    var dateTimeDigitized: String?
    var offsetTimeDigitized: String?
    var tiffDateTime: String?
    var make: String?
    var model: String?
    var lensModel: String?
    var profileName: String?
    var dpiWidth: Double?
    var orientation: Int?
    var width: Int = 320
    var height: Int = 240
    var latitude: Double?
    var latitudeReference: String?
    var longitude: Double?
    var longitudeReference: String?
    var altitude: Double?
    var altitudeReference: Int?
    var speedKilometersPerHour: Double?
    var gpsDateStamp: String?
    var gpsTimeStamp: String?
    var frames: Int = 1

    // MARK: - Writing

    func properties() -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        var tiff: [CFString: Any] = [:]
        var gps: [CFString: Any] = [:]

        exif[kCGImagePropertyExifDateTimeOriginal] = dateTimeOriginal
        exif[kCGImagePropertyExifSubsecTimeOriginal] = subsecTimeOriginal
        exif[kCGImagePropertyExifOffsetTimeOriginal] = offsetTimeOriginal
        exif[kCGImagePropertyExifDateTimeDigitized] = dateTimeDigitized
        exif[kCGImagePropertyExifOffsetTimeDigitized] = offsetTimeDigitized
        exif[kCGImagePropertyExifLensModel] = lensModel
        tiff[kCGImagePropertyTIFFDateTime] = tiffDateTime
        tiff[kCGImagePropertyTIFFMake] = make
        tiff[kCGImagePropertyTIFFModel] = model
        tiff[kCGImagePropertyTIFFXResolution] = dpiWidth
        tiff[kCGImagePropertyTIFFOrientation] = orientation
        tiff[kCGImagePropertyProfileName] = profileName
        gps[kCGImagePropertyGPSLatitude] = latitude
        gps[kCGImagePropertyGPSLatitudeRef] = latitudeReference
        gps[kCGImagePropertyGPSLongitude] = longitude
        gps[kCGImagePropertyGPSLongitudeRef] = longitudeReference
        gps[kCGImagePropertyGPSAltitude] = altitude
        gps[kCGImagePropertyGPSAltitudeRef] = altitudeReference
        gps[kCGImagePropertyGPSSpeed] = speedKilometersPerHour
        gps[kCGImagePropertyGPSDateStamp] = gpsDateStamp
        gps[kCGImagePropertyGPSTimeStamp] = gpsTimeStamp

        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        return properties
    }

    /// Encodes the file and returns its URL. `type` may be `.heic` or `.png`; a container the encoder does
    /// not have on this machine is reported rather than silently downgraded, because a test that quietly
    /// stopped testing HEIC is worse than one that says it skipped.
    @discardableResult
    func write(into directory: URL, named name: String, type: UTType = .jpeg) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let image = raster(width: width, height: height) else {
            throw FixtureFailure.noBitmap
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, max(1, frames), nil
        ) else {
            throw FixtureFailure.noEncoder(type)
        }
        // An animated container is the only case that wants more than one frame, and the frame count is
        // what the reader's `frameCount` must come back as.
        for _ in 0..<max(1, frames) {
            CGImageDestinationAddImage(destination, image, properties() as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FixtureFailure.noEncoder(type) }
        return url
    }

    enum FixtureFailure: Error, CustomStringConvertible {
        case noBitmap
        case noEncoder(UTType)

        var description: String {
            switch self {
            case .noBitmap: "could not build a bitmap to encode"
            case .noEncoder(let type): "this machine has no \(type.preferredFilenameExtension ?? type.identifier) encoder"
            }
        }
    }
}

/// A flat grey raster, built by hand so the fixture depends on no stock photo — and so a big decode can be
/// simulated by asking for a bigger number rather than by downloading one.
func raster(width: Int, height: Int) -> CGImage? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: max(1, width), pixelsHigh: max(1, height),
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )?.cgImage
}
