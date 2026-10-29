import CoreLocation
import Foundation
import GalleryDomain
import MapKit

public enum GeocodeError: Error, Equatable, Sendable {
    /// The service (or the network) is not available. A run stops at the first one of these instead of
    /// asking about the next twenty places that would fail identically.
    case unavailable
    /// There is nothing to name at this coordinate — open ocean, mostly. Recorded so it is not retried.
    case noResult
}

/// Reverse geocoding behind a protocol so the deriver can be tested with a count, a failure and no network.
public protocol ReverseGeocoding: Sendable {
    func placemark(for point: GPSPoint) async throws -> PlaceSummary
}

/// Apple's geocoder, by whatever path the OS still supports.
///
/// `CLGeocoder` is deprecated as of macOS 26 and `MKReverseGeocodingRequest` only exists from macOS 26, so
/// the app carries both: the deployment floor is macOS 15, and a gallery that only names places on the
/// newest OS would be a regression for everyone else.
public final class AppleGeocoder: ReverseGeocoding, @unchecked Sendable {
    public init() {}

    public func placemark(for point: GPSPoint) async throws -> PlaceSummary {
        if #available(macOS 26.0, *) {
            return try await Self.mapKitPlacemark(for: point)
        }
        return try await Self.coreLocationPlacemark(for: point)
    }

    @MainActor
    @available(macOS 26.0, *)
    private static func mapKitPlacemark(for point: GPSPoint) async throws -> PlaceSummary {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw GeocodeError.noResult
        }
        let items: [MKMapItem]
        do {
            items = try await request.mapItems
        } catch {
            // An empty answer is "no place here"; a thrown error is the service being unusable, which is
            // the signal to stop asking rather than to keep going down the list.
            throw classify(error)
        }
        guard let item = items.first else { throw GeocodeError.noResult }
        // `MKMapItem.name` is the place ("Kiyomizu-dera"); `address` is the street-level fallback. The
        // structured locality/country live only on the deprecated placemark, so the title is the name and
        // the subtitle is the short address.
        return PlaceSummary(name: item.name, locality: item.address?.shortAddress)
    }

    private static func coreLocationPlacemark(for point: GPSPoint) async throws -> PlaceSummary {
        let marks: [CLPlacemark]
        do {
            marks = try await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: point.latitude, longitude: point.longitude)
            )
        } catch {
            throw classify(error)
        }
        guard let place = marks.first else { throw GeocodeError.noResult }
        return PlaceSummary(
            name: place.name,
            locality: place.locality,
            subLocality: place.subLocality,
            adminArea: place.administrativeArea,
            country: place.country,
            isoCountryCode: place.isoCountryCode
        )
    }

    private static func classify(_ error: Error) -> GeocodeError {
        if (error as NSError).domain == NSURLErrorDomain { return .unavailable }
        if let cle = error as? CLError {
            // The geocoder answering "there is nothing there" is a fact; everything else is the service
            // refusing to answer, which is a reason to stop for this run.
            return cle.code == .geocodeFoundNoResult ? .noResult : .unavailable
        }
        return .unavailable
    }
}
