import Foundation

/// How specifically a cluster was named. The ladder decides what the album title shows; `grid` is what
/// you get with no network, and is still a usable album.
public enum ClusterLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case precise
    case street
    case city
    case country
    case grid

    public var isNamed: Bool { self != .grid }
}

public struct PlaceSummary: Sendable, Hashable, Codable {
    public var name: String?
    public var locality: String?
    public var subLocality: String?
    public var adminArea: String?
    public var country: String?
    public var isoCountryCode: String?

    public init(
        name: String? = nil,
        locality: String? = nil,
        subLocality: String? = nil,
        adminArea: String? = nil,
        country: String? = nil,
        isoCountryCode: String? = nil
    ) {
        self.name = name
        self.locality = locality
        self.subLocality = subLocality
        self.adminArea = adminArea
        self.country = country
        self.isoCountryCode = isoCountryCode
    }

    /// name → locality → subLocality → adminArea → country. Deliberately falls through to the coarsest
    /// truth rather than showing an empty title.
    public var displayName: String? {
        [name, locality, subLocality, adminArea, country].compactMap { $0 }.first
    }

    /// The key location albums are grouped by, so five clusters inside one city collapse to one album row.
    public var placeKey: String? {
        guard let primary = displayName else { return nil }
        return [primary, adminArea, country].compactMap { $0 }.joined(separator: "|")
    }
}

public struct LocationCluster: Identifiable, Sendable, Hashable, Codable {
    public let id: ClusterID
    public var center: GPSPoint
    public var radiusMeters: Double
    public var count: Int
    public var placemark: PlaceSummary?
    public var level: ClusterLevel

    public init(
        id: ClusterID,
        center: GPSPoint,
        radiusMeters: Double,
        count: Int,
        placemark: PlaceSummary? = nil,
        level: ClusterLevel = .grid
    ) {
        self.id = id
        self.center = center
        self.radiusMeters = radiusMeters
        self.count = count
        self.placemark = placemark
        self.level = level
    }

    public var title: String {
        if let named = placemark?.displayName, level.isNamed { return named }
        return center.offlinePlaceLabel
    }

    /// A cluster with no name yet is still a real album — geocoding is a refinement, never a prerequisite.
    public var awaitsGeocoding: Bool { placemark?.displayName == nil }
}
