import Foundation
import Observation
import GalleryDomain
import GalleryEditing

/// The batch metadata sheet's fields, each with its own "apply" switch so a selection can get a title without
/// touching the dates it may not share.
@MainActor
@Observable
public final class BatchMetadataSession {
    public let count: Int
    public var applyTitle = false
    public var title = ""
    public var applyDate = false
    public var date = Date()
    public var applyLocation = false
    public var latitude = ""
    public var longitude = ""

    public init(count: Int) {
        self.count = count
    }

    public var overrides: MetadataOverrides? {
        var result = MetadataOverrides()
        if applyTitle {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.title = trimmed.isEmpty ? .clear : .set(trimmed)
        }
        if applyDate {
            result.capture = .set(CaptureEdit(
                instant: date, offsetSeconds: TimeZone.current.secondsFromGMT(for: date)
            ))
        }
        if applyLocation {
            if let latitude = Double(latitude.trimmingCharacters(in: .whitespaces)),
               let longitude = Double(longitude.trimmingCharacters(in: .whitespaces)),
               (-90...90).contains(latitude), (-180...180).contains(longitude) {
                result.gps = .set(GPSPoint(latitude: latitude, longitude: longitude))
            } else {
                result.gps = .clear
            }
        }
        return result.isEmpty ? nil : result
    }
}
