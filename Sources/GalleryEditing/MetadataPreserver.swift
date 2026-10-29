import Foundation
import ImageIO

/// Carries the metadata a camera wrote into a re-encoded copy, minus the fields a geometric edit makes
/// untrue.
///
/// ImageIO cannot edit a finished file, so preservation happens at encode time. What is deliberately
/// dropped: orientation (the pixels are upright now; copying a stale `6` produces the classic sideways
/// export), the pixel dimensions and colour model (ImageIO writes those from the bitmap), the subject area
/// and location (a crop invalidates them), maker notes and the camera maker dictionary (a re-encode cannot
/// carry private blocks — the UI says so), and the baked thumbnail (ImageIO regenerates it).
public enum MetadataPreserver {
    private static let droppedTopLevel: Set<String> = [
        kCGImagePropertyOrientation as String,
        kCGImagePropertyPixelWidth as String,
        kCGImagePropertyPixelHeight as String,
        kCGImagePropertyProfileName as String,
        kCGImagePropertyColorModel as String,
        kCGImagePropertyFileSize as String,
        kCGImagePropertyExifAuxDictionary as String,
        kCGImagePropertyMakerAppleDictionary as String,
    ]

    private static let droppedExif: Set<String> = [
        kCGImagePropertyExifPixelXDimension as String,
        kCGImagePropertyExifPixelYDimension as String,
        kCGImagePropertyExifSubjectArea as String,
        kCGImagePropertyExifSubjectLocation as String,
        kCGImagePropertyExifMakerNote as String,
    ]

    private static let droppedTiff: Set<String> = [
        kCGImagePropertyTIFFOrientation as String,
    ]

    public static func properties(from source: [CFString: Any], plan: EditPlan) -> [CFString: Any] {
        var result: [CFString: Any] = [:]
        result.reserveCapacity(source.count)
        for (key, value) in source where !droppedTopLevel.contains(key as String) {
            if key == kCGImagePropertyExifDictionary, let exif = value as? [CFString: Any] {
                var filtered = exif
                for drop in droppedExif { filtered.removeValue(forKey: drop as CFString) }
                result[key] = filtered
            } else if key == kCGImagePropertyTIFFDictionary, let tiff = value as? [CFString: Any] {
                var filtered = tiff
                for drop in droppedTiff { filtered.removeValue(forKey: drop as CFString) }
                result[key] = filtered
            } else {
                result[key] = value
            }
        }
        return result
    }
}
